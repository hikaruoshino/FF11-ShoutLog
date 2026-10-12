-- =============================================================================
-- ShoutLog.lua : シャウトとエールを覚えておき、あとから小さな窓で読み返すアドオン (v1.5.0)
-- =============================================================================
-- 【目的】
-- ソロで遊んでいる間に、参加したかった募集のシャウト・エールを見逃さないようにする。
--
-- 【概要】
-- 受け取ったシャウト (/shout) とエール (/yell) を覚えておき、コマンドで開く窓に一覧で出す。
-- 英語だけの発言 (ひらがな・カタカナ・漢字を 1 文字も含まないもの) は覚えない。
-- Guildwork プラグインの「/gw shouts」(サーバー全体の発言) の出力からも、英語だけの発言を消す。
-- ゲームのサーバーへ送る操作 (発言・魔法・アイテムなど) や、コマンドを自動で打つことは一切しない。
--
-- 【動き】
--   - 受け取り : chat message イベント (シャウト = 1 / エール = 26)。定型文は日本語に直してから判定する
--   - 表示     : 窓を開いている間、内容が変わったときだけ書き直す
--   - 記録     : メモリの中だけ (最大 MAX_ENTRIES 件)。ファイルには書かない。エリアを変えても消さない
--
-- 【文字コード】
--   - 窓 (libs/texts.lua) : UTF-8
--   - チャット (windower.add_to_chat) : Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "ShoutLog"
_addon.author   = "hikaruoshino"
_addon.version  = "1.5.0"
_addon.commands = {"shoutlog", "shl"}

require("luau")
local config = require("config")
local texts  = require("texts")

-- -----------------------------------------------------------------------------
-- デフォルト設定 (data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {}
defaults.pos = {x = 400, y = 200}
defaults.text = {font = "Meiryo", size = 10, alpha = 255}
defaults.bg = {alpha = 200, red = 10, green = 10, blue = 15}
defaults.padding = 6
defaults.lines = 12            -- 一度に出す発言の数
defaults.width = 44            -- 1 行の幅 (全角の文字数)。これを超えたら折り返す
defaults.japanese_only = true  -- 英語だけの発言を覚えない
defaults.gw_filter = true      -- Guildwork の「/gw shouts」の出力から、英語だけの発言を消す (japanese_only がオンのとき)
defaults.allow_names = ""         -- 英語だけでも消さない人の名前 (カンマ区切り。大文字小文字は区別しない。//shl allow name で足す)
defaults.allow_words = ""         -- 英語だけでも消さない言葉 (カンマ区切り。本文に含まれていれば消さない。//shl allow word で足す)
defaults.gw_takeover = false   -- 「/gw shouts」でもこの窓を開く (Guildwork プラグインを外しているとき用)

local settings = config.load(defaults)

-- -----------------------------------------------------------------------------
-- 定数
-- -----------------------------------------------------------------------------
local MODE_SHOUT, MODE_YELL = 1, 26
local MODE_LABEL = {[MODE_SHOUT] = "シャウト", [MODE_YELL] = "エール"}
local MODE_COLOR = {[MODE_SHOUT] = {255, 170, 110}, [MODE_YELL] = {255, 235, 120}}
local MAX_ENTRIES = 200           -- 覚えておく発言の数 (古いものから捨てる)
local REPEAT_SEC = 600            -- 同じ人の同じ発言がこの秒数以内にまた来たら、行を増やさず時刻だけ新しくする
local MOUSE_WHEEL = 10
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- -----------------------------------------------------------------------------
-- ヘルパー
-- -----------------------------------------------------------------------------
local function chat_msg(msg, color)
    color = color or 207
    if windower.to_shift_jis then
        local ok, converted = pcall(windower.to_shift_jis, tostring(msg))
        if ok and converted then
            windower.add_to_chat(color, converted)
            return
        end
    end
    windower.add_to_chat(color, tostring(msg))
end

local function color_text(str, r, g, b)
    return string.format("\\cs(%d,%d,%d)%s\\cr", r, g, b, tostring(str or ""))
end

-- ひらがな・カタカナ・漢字・半角カナを 1 文字でも含むか (UTF-8 の文字列を調べる)
--   U+3040〜30FF = E3 81〜83 xx / U+3400〜9FFF = E4〜E9 xx xx / U+FF66〜FF9F = EF BD A6 〜 EF BE 9F
local function has_japanese(utf8)
    if utf8:find("\227[\129-\131][\128-\191]") then return true end
    if utf8:find("\227\128[\129-\191]") then return true end   -- 「、。〆々」などの記号 (U+3001〜303F。全角の空白は数えない)
    if utf8:find("[\228-\233][\128-\191][\128-\191]") then return true end
    if utf8:find("\239\189[\166-\191]") or utf8:find("\239\190[\128-\159]") then return true end
    -- 例外: 「sime」は日本人が募集を締め切るときに使う言葉 (〆と同じ意味) なので、日本語として扱う
    if (" " .. utf8:lower() .. " "):find("[^%a]sime[^%a]") then return true end
    if utf8:find("ｓｉｍｅ", 1, true) or utf8:find("ＳＩＭＥ", 1, true) or utf8:find("Ｓｉｍｅ", 1, true) then return true end
    return false
end

-- 例外の一覧 (設定はカンマ区切りの文字列)。設定を変えたら allow_cache を捨てて作り直す
local allow_cache = nil
local function split_list(value)
    local list = {}
    for item in tostring(value or ""):gmatch("[^,]+") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then list[#list + 1] = item end
    end
    return list
end

local function allow_lists()
    if not allow_cache then
        allow_cache = {names = {}, words = {}}
        for _, name in ipairs(split_list(settings.allow_names)) do allow_cache.names[name:lower()] = true end
        for _, word in ipairs(split_list(settings.allow_words)) do allow_cache.words[#allow_cache.words + 1] = word:lower() end
    end
    return allow_cache
end

-- 表示してよい発言か: 日本語を含む / 例外の人の発言 / 例外の言葉を含む
local function is_wanted(sender, utf8)
    if has_japanese(utf8) then return true end
    local allow = allow_lists()
    if allow.names[tostring(sender or ""):lower()] then return true end
    local lower = utf8:lower()
    for _, word in ipairs(allow.words) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

-- 受け取った発言 (Shift-JIS・定型文の符号入り) を、窓に出せる UTF-8 の 1 行にする
local function to_display(message)
    local text = tostring(message or "")
    if windower.convert_auto_trans then
        local ok, converted = pcall(windower.convert_auto_trans, text)
        if ok and converted then text = converted end
    end
    if windower.from_shift_jis then
        local ok, converted = pcall(windower.from_shift_jis, text)
        if ok and converted then text = converted end
    end
    text = text:gsub("[%z\1-\31\127]", " ")   -- 改行などの制御文字
    text = text:gsub("\\", "＼")              -- texts の色指定 (\cs) と取り違えないように
    text = text:gsub("%${", "$ {")            -- texts の変数 (${...}) と取り違えないように
    text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return text
end

-- 全角を 1、半角を 0.5 と数えて、幅 width で折り返す
local function wrap(utf8, width)
    local out, line, used = {}, {}, 0
    for ch in utf8:gmatch(UTF8_CHAR) do
        local w = #ch == 1 and 0.5 or 1
        if used + w > width and #line > 0 then
            out[#out + 1] = table.concat(line)
            line, used = {}, 0
        end
        line[#line + 1] = ch
        used = used + w
    end
    if #line > 0 then out[#out + 1] = table.concat(line) end
    return out
end

-- -----------------------------------------------------------------------------
-- 状態
-- -----------------------------------------------------------------------------
local entries = {}     -- 古い順。{at = os.time(), mode = 種類, sender = 名前, text = 本文 (UTF-8), count = 回数}
local offset = 0       -- いちばん新しい発言から何件さかのぼって表示しているか (ホイールで変える)
local visible = false
local window = texts.new("", settings)

-- -----------------------------------------------------------------------------
-- 表示
-- -----------------------------------------------------------------------------
local function render()
    if not visible then return end
    local per_page = math.max(3, math.min(40, tonumber(settings.lines) or 12))
    local width = math.max(20, math.min(100, tonumber(settings.width) or 44))
    offset = math.max(0, math.min(offset, math.max(0, #entries - per_page)))

    local lines = {}
    local last = #entries - offset
    local first = math.max(1, last - per_page + 1)
    lines[#lines + 1] = color_text(string.format("=== シャウト・エール%s  %d 件%s ===",
        settings.japanese_only and " (日本語のみ)" or "",
        #entries,
        offset > 0 and string.format(" / %d 件前を表示中" , offset) or ""), 200, 220, 255)
    if #entries == 0 then
        lines[#lines + 1] = color_text("まだ受け取っていません。", 180, 180, 180)
    end
    for i = first, last do
        local e = entries[i]
        local c = MODE_COLOR[e.mode]
        local head = string.format("%s %s %s%s", os.date("%H:%M", e.at), MODE_LABEL[e.mode], e.sender,
            e.count > 1 and string.format(" (%d 回)", e.count) or "")
        lines[#lines + 1] = color_text(head, c[1], c[2], c[3])
        for _, part in ipairs(wrap(e.text, width)) do
            lines[#lines + 1] = "  " .. part
        end
    end
    lines[#lines + 1] = color_text("ホイール: さかのぼる / //shl: 閉じる", 140, 140, 140)
    window:text(table.concat(lines, string.char(10)))
    if not window:visible() then window:show() end
end

local function set_visible(flag)
    visible = flag
    if visible then
        offset = 0
        render()
    else
        window:hide()
        config.save(settings)   -- ドラッグで動かした位置を残す
    end
end

-- -----------------------------------------------------------------------------
-- 受け取り
-- -----------------------------------------------------------------------------
local function add_entry(mode, sender, text)
    local now = os.time()
    -- 同じ人が同じ発言を繰り返しているときは、行を増やさずいちばん下へ移す
    for i = #entries, 1, -1 do
        local e = entries[i]
        if now - e.at > REPEAT_SEC then break end
        if e.sender == sender and e.mode == mode and e.text == text then
            table.remove(entries, i)
            e.at, e.count = now, e.count + 1
            entries[#entries + 1] = e
            render()
            return
        end
    end

    entries[#entries + 1] = {at = now, mode = mode, sender = sender, text = text, count = 1}
    if #entries > MAX_ENTRIES then table.remove(entries, 1) end
    -- さかのぼって読んでいる途中は、読んでいる場所がずれないようにする
    if offset > 0 then offset = offset + 1 end
    render()
end

local function on_chat(message, sender, mode)
    if mode ~= MODE_SHOUT and mode ~= MODE_YELL then return end
    local text = to_display(message)
    if text == "" then return end
    if settings.japanese_only and not is_wanted(sender, text) then return end
    add_entry(mode, tostring(sender or "?"), text)
end

local last_error_at = -100
local function report_error(label, err)
    -- 同じエラーでチャットを埋めないよう 10 秒に 1 回だけ知らせる
    local now = os.clock()
    if now - last_error_at > 10 then
        last_error_at = now
        chat_msg("[ShoutLog] " .. label .. ": " .. tostring(err), 167)
    end
end

windower.register_event("chat message", function(message, sender, mode)
    local ok, err = pcall(on_chat, message, sender, mode)
    if not ok then report_error("受け取りエラー", err) end
end)

-- 窓の上でホイールを回すと、古い発言へさかのぼる (true を返すとホイールをゲームに渡さない)
windower.register_event("mouse", function(mtype, x, y, delta, blocked)
    if blocked or not visible or mtype ~= MOUSE_WHEEL then return end
    local ok, result = pcall(function()
        if not window:hover(x, y) then return end
        offset = offset + ((tonumber(delta) or 0) > 0 and 1 or -1)
        render()
        return true
    end)
    if ok then return result end
    report_error("マウス処理エラー", result)
end)

-- -----------------------------------------------------------------------------
-- Guildwork プラグインの「/gw shouts」
--   プラグインは、サーバー全体のシャウト・エールを「名前[???]: 本文」の形 (種類 3) で、古い順にチャットログへ出す。
--   「/gw shouts」を打ってから GW_WINDOW_SEC 秒の間に届いたその形の行のうち、英語だけの発言を消す。
--   その形でない行には触らない
-- -----------------------------------------------------------------------------
local GW_WINDOW_SEC = 8           -- 自分で打ったあと、出力が届くのを待つ秒数
local GW_MODE = 3                 -- プラグインが出す行の種類

local gw = {
    until_at = 0,      -- この時刻まで、届いた行を調べる (0 = 調べていない)
    shown = 0, hidden = 0,
}

-- 「名前[???]: 本文」の行を名前と本文 (UTF-8) に分ける。その形でなければ nil
local function parse_gw_line(original)
    local name, body = tostring(original or ""):match("^([%a%d_%-']+)%[[^%]]*%]: (.*)$")
    if not name then return nil end
    if windower.from_shift_jis then
        local ok, converted = pcall(windower.from_shift_jis, body)
        if ok and converted then body = converted end
    end
    return name, body
end

windower.register_event("incoming text", function(original, modified, original_mode)
    if gw.until_at == 0 or original_mode ~= GW_MODE then return end
    if os.clock() > gw.until_at then return end
    local ok, name, body = pcall(parse_gw_line, original)
    if not ok or not name then return end
    if not (settings.gw_filter and settings.japanese_only) then return end
    if not is_wanted(name, body) then
        gw.hidden = gw.hidden + 1
        return true
    end
    gw.shown = gw.shown + 1
end)

-- 「/gw shouts」が打たれたとき: 自分で打った分なら上の絞り込みを始める。
-- 設定 gw_takeover がオンなら、代わりにこの窓を開く (発言はゲームに送らない)
windower.register_event("outgoing text", function(original)
    local is_shouts = tostring(original or ""):lower():find("^/gw%s+shout") ~= nil
    if is_shouts then
        gw.until_at = os.clock() + GW_WINDOW_SEC
        gw.shown, gw.hidden = 0, 0
    end
    if not settings.gw_takeover then return end
    local text = tostring(original or ""):lower():gsub("%s+", " "):gsub(" $", "")
    if text == "/gw shouts" or text == "/gw shout" then
        local ok, err = pcall(set_visible, not visible)
        if not ok then report_error("表示エラー", err) end
        return true
    end
end)

-- -----------------------------------------------------------------------------
-- クリーンアップ
-- -----------------------------------------------------------------------------
-- エリアを変えても発言の記録は残す (あとから読み返すためのもの。持っているのは文字列だけ)
windower.register_event("logout", function()
    entries = {}
    offset = 0
    gw.until_at = 0
    if visible then set_visible(false) end
end)
windower.register_event("unload", function()
    if window then
        config.save(settings)
        window:destroy()
    end
end)

-- -----------------------------------------------------------------------------
-- コマンド (//shl または //shoutlog)
-- -----------------------------------------------------------------------------
windower.register_event("addon command", function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower()

    if cmd == nil or cmd == "shouts" or cmd == "show" or cmd == "toggle" then
        set_visible(not visible)

    elseif cmd == "hide" then
        set_visible(false)

    elseif cmd == "clear" then
        entries = {}
        offset = 0
        render()
        chat_msg("[ShoutLog] 記録を消しました。")

    elseif cmd == "lines" and tonumber(args[1]) then
        settings.lines = math.max(3, math.min(40, math.floor(tonumber(args[1]))))
        config.save(settings)
        render()
        chat_msg(string.format("[ShoutLog] 一度に出す発言の数を %d にしました。", settings.lines))

    elseif cmd == "width" and tonumber(args[1]) then
        settings.width = math.max(20, math.min(100, math.floor(tonumber(args[1]))))
        config.save(settings)
        render()
        chat_msg(string.format("[ShoutLog] 1 行の幅を全角 %d 文字にしました。", settings.width))

    elseif cmd == "size" and tonumber(args[1]) then
        local size = math.max(6, math.min(40, math.floor(tonumber(args[1]))))
        window:size(size)
        config.save(settings)
        chat_msg(string.format("[ShoutLog] 文字サイズを %d にしました。", size))

    elseif cmd == "all" then
        settings.japanese_only = not settings.japanese_only
        config.save(settings)
        render()
        chat_msg(string.format("[ShoutLog] 英語だけの発言: %s (これから受け取る分に効きます)",
            settings.japanese_only and "覚えない" or "覚える"))

    elseif cmd == "allow" then
        -- //shl allow : 例外の一覧 / //shl allow name <名前> ・ //shl allow word <言葉> : 足す (もう一度打つと外す)
        local kind = args[1] and args[1]:lower()
        local value = args[2] and table.concat(args, " ", 2)
        if windower.from_shift_jis and value then
            local ok, converted = pcall(windower.from_shift_jis, value)
            if ok and converted then value = converted end
        end
        local key = (kind == "name" and "allow_names") or (kind == "word" and "allow_words") or nil
        if key and value and value ~= "" and not value:find(",", 1, true) then
            local list, found = split_list(settings[key]), false
            for i = #list, 1, -1 do
                if list[i]:lower() == value:lower() then table.remove(list, i); found = true end
            end
            if not found then list[#list + 1] = value end
            settings[key] = table.concat(list, ",")
            allow_cache = nil
            config.save(settings)
            chat_msg(string.format("[ShoutLog] 例外の%s「%s」を%s。", kind == "name" and "人" or "言葉", value, found and "外しました" or "足しました"))
        end
        chat_msg("[ShoutLog] 英語だけでも消さない人: " .. (table.concat(split_list(settings.allow_names), " / ")))
        chat_msg("[ShoutLog] 英語だけでも消さない言葉: " .. (table.concat(split_list(settings.allow_words), " / ")))

    elseif cmd == "gwfilter" then
        settings.gw_filter = not settings.gw_filter
        config.save(settings)
        chat_msg(string.format("[ShoutLog] 「/gw shouts」の出力から英語だけの発言を消す: %s", settings.gw_filter and "ON" or "OFF"))

    elseif cmd == "status" then
        chat_msg(string.format("[ShoutLog] 英語だけの発言を消す: 窓 %s / 「/gw shouts」の出力 %s (前回: 表示 %d 行・消した %d 行)",
            settings.japanese_only and "ON" or "OFF", (settings.gw_filter and settings.japanese_only) and "ON" or "OFF", gw.shown, gw.hidden))

    elseif cmd == "gw" then
        settings.gw_takeover = not settings.gw_takeover
        config.save(settings)
        chat_msg(string.format("[ShoutLog] 「/gw shouts」でこの窓を開く: %s", settings.gw_takeover and "ON" or "OFF"))

    else
        chat_msg("=== ShoutLog コマンドヘルプ ===")
        chat_msg("//shl              : 窓を開く / 閉じる")
        chat_msg("//shl clear        : 記録を消す")
        chat_msg("//shl lines <数>   : 一度に出す発言の数 (3〜40、初期値 12)")
        chat_msg("//shl width <数>   : 1 行の幅 (全角の文字数 20〜100、初期値 44)")
        chat_msg("//shl size <数>    : 文字サイズ (6〜40)")
        chat_msg("//shl all          : 英語だけの発言も覚える / 覚えない")
        chat_msg("//shl allow        : 英語だけでも消さない人・言葉の一覧")
        chat_msg("//shl allow name <名前> : 例外の人を足す (もう一度打つと外す)")
        chat_msg("//shl allow word <言葉> : 例外の言葉を足す (もう一度打つと外す)")
        chat_msg("//shl gwfilter     : Guildwork の「/gw shouts」の出力から英語だけの発言を消す ON/OFF")
        chat_msg("//shl status       : 設定と、前回の「/gw shouts」で消した行数")
        chat_msg("//shl gw           : 「/gw shouts」でもこの窓を開く ON/OFF (Guildwork を外しているとき用)")
    end
end)
