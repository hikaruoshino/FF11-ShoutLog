-- =============================================================================
-- ShoutLog.lua : シャウトとエールを覚えておき、あとから小さな窓で読み返すアドオン (v1.6.1)
-- =============================================================================
-- 【目的】
-- ソロで遊んでいる間に、参加したかった募集のシャウト・エールを見逃さないようにする。
--
-- 【概要】
-- 受け取ったシャウト (/shout) とエール (/yell) を覚えておき、コマンドで開く窓に一覧で出す。
-- 英語だけの発言 (ひらがな・カタカナ・漢字を 1 文字も含まないもの) は覚えない。
-- Guildwork プラグインの「/gw shouts」(サーバー全体の発言) の出力からも、英語だけの発言を消す。
-- ゲームのサーバーへ送る操作 (発言・魔法・アイテムなど) は一切しない。
--
-- 【隠しコマンド: 見張り】 (README と //shl help には載せていない。ここを読んだ人だけが使える)
--   //shl watch          : 見張りの ON / OFF (初期値は OFF)。一定の間隔で「/gw shouts」を自動で打ち、
--                          前回から増えた発言だけを「[遠くのシャウト] 名前: 本文」でチャットログに知らせる
--   //shl watch <秒>     : 見張りの間隔 (60〜600、初期値 120)
--   //shl watch sound    : 新しい発言の音の ON / OFF (sounds/notify.wav を自分で置いたときだけ鳴る)
--   //shl mode <番号>    : 知らせに付けるチャットの種類 (色と、ゲームのどのログウィンドウに出るかが変わる。初期値 207)
--   //shl modetest       : 種類ごとの見本を出す (どのログウィンドウに出るかを調べる)
--   ・一覧そのものは表示しない。始めた直後の 1 回は、今ある発言を覚えるだけ
--   ・直接届いた発言 (今いるエリアのシャウト・届いたエール) は、見張りでは重ねて知らせない
--   ・自動で打つのは Guildwork プラグインが受け取る「/gw shouts」だけ。応答が 3 回続けて無ければ自分で止まる
--   ・見張りのたびに Guildwork のサーバーへ問い合わせが行く。間隔を必要以上に短くしないこと
--     (載せていないのは、気軽に大勢が使うとサーバーの負担になるため)
--
-- 【動き】
--   - 受け取り : chat message イベント (シャウト = 1 / エール = 26)。定型文は日本語に直してから判定する
--   - 表示     : 窓を開いている間、内容が変わったときだけ書き直す
--   - 見張り   : prerender で時刻を比べるだけ。間隔が来たときに「/gw shouts」を 1 回打つ
--              届いた発言の {English} (定型文・アイテム名) は、res の英語名から日本語に直して知らせる
--   - 記録     : メモリの中だけ (最大 MAX_ENTRIES 件)。ファイルには書かない。エリアを変えても消さない
--
-- 【文字コード】
--   - 窓 (libs/texts.lua) : UTF-8
--   - チャット (windower.add_to_chat) : Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "ShoutLog"
_addon.author   = "hikaruoshino"
_addon.version  = "1.6.1"
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
defaults.watch = false         -- 見張り: 一定の間隔で「/gw shouts」を打ち、新しい発言を知らせる
defaults.watch_interval = 120  -- 見張りの間隔 (秒。60〜600。Guildwork のサーバーへ問い合わせるので、短くしすぎない)
defaults.notify_mode = 207     -- 見張りの知らせを出すチャットの種類 (色と、ゲームのどのログウィンドウに出るかが決まる)
defaults.watch_sound = true    -- 新しい発言があったとき sounds/notify.wav を鳴らす (ファイルがあるときだけ)
defaults.gw_takeover = false   -- 「/gw shouts」でもこの窓を開く (Guildwork プラグインを外しているとき用)

local settings = config.load(defaults)

-- -----------------------------------------------------------------------------
-- 定数
-- -----------------------------------------------------------------------------
local MODE_SHOUT, MODE_YELL = 1, 26
local MODE_GW = "gw"              -- Guildwork 経由で知った発言 (シャウトとエールの区別は付かない)
local MODE_LABEL = {[MODE_SHOUT] = "シャウト", [MODE_YELL] = "エール", [MODE_GW] = "遠く"}
local MODE_COLOR = {[MODE_SHOUT] = {255, 170, 110}, [MODE_YELL] = {255, 235, 120}, [MODE_GW] = {150, 220, 255}}
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
-- 直接届いたシャウト・エールの覚え書き。同じ発言は、あとから見張り (Guildwork 経由) でも届くので、
-- そちらでは知らせないようにするために使う (絞り込みで窓に出さなかった発言も覚える)
local DIRECT_KEEP_SEC = 900       -- 覚えておく秒数 (見張りの間隔は最長 600 秒)
local direct_heard = {}           -- 古い順。{at = os.clock(), sender = 名前 (小文字), key = 空白を除いた本文}

-- 比べるための形: 半角・全角の空白と定型文の括弧 { } を除き、英字は小文字にする
-- (Guildwork 経由の本文は、空白の入り方が直接届いた本文と少し違う。定型文の括弧は片方にしか無いことがある)
local function squash(text)
    return (tostring(text or ""):gsub("[%s{}]+", ""):gsub("　", ""):lower())
end

local function remember_direct(sender, text)
    local now = os.clock()
    while direct_heard[1] and now - direct_heard[1].at > DIRECT_KEEP_SEC do table.remove(direct_heard, 1) end
    direct_heard[#direct_heard + 1] = {at = now, sender = tostring(sender or ""):lower(), key = squash(text)}
end

-- 見張りで届いた発言 (名前と、clean_gw_body を通した本文) が、すでに直接届いたものか。
-- 定型文は、直接届いた分は日本語、Guildwork 経由は英語を {…} で囲んだ形になるので、
-- {…} の外側の文字だけを順番に探して比べる (外側に 4 バイト以上の文字があるときだけ)
local function heard_directly(name, body)
    local now = os.clock()
    local sender = tostring(name or ""):lower()
    local key = squash(body)
    local parts, literal = {}, 0
    for part in (body .. "{}"):gmatch("(.-)%b{}") do
        part = squash(part)
        if part ~= "" then
            parts[#parts + 1] = part
            literal = literal + #part
        end
    end
    for i = #direct_heard, 1, -1 do
        local d = direct_heard[i]
        if now - d.at > DIRECT_KEEP_SEC then break end
        if d.sender == sender then
            if d.key == key then return true end
            if #parts > 0 and literal >= 4 and body:find("{", 1, true) then
                local pos, all = 1, true
                for _, part in ipairs(parts) do
                    local from, to = d.key:find(part, pos, true)
                    if not from then all = false; break end
                    pos = to + 1
                end
                if all then return true end
            end
        end
    end
    return false
end

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
    remember_direct(sender, text)
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
--   (1) 自分で打ったとき: 打ってから GW_WINDOW_SEC 秒の間に届いたその形の行のうち、英語だけの発言を消す
--   (2) 見張り          : 一定の間隔でこのアドオンが打ち、届いた行は全部隠して、前回から増えた発言だけを知らせる
--   どちらも、その形でない行には触らない
-- -----------------------------------------------------------------------------
local GW_WINDOW_SEC = 8           -- 自分で打ったあと、出力が届くのを待つ秒数
local GW_POLL_WAIT_SEC = 4        -- 見張りで打ったあと、出力が届くのを待つ秒数
local GW_MODE = 3                 -- プラグインが出す行の種類
local GW_MODE_ALT = 2             -- 2026-10-15 以降の版は、一部の行 (長い発言の続きなど) を種類 2 で出す。"[???]" の行だけ対象にする
local GW_MAX_MISSES = 3           -- 見張りで、この回数続けて応答が無ければ止める (プラグインが無い・ログインしていない)
local WATCH_MIN_SEC, WATCH_MAX_SEC = 60, 600
local NOTIFY_SOUND = windower.addon_path .. "sounds/notify.wav"

local gw = {
    until_at = 0,      -- この時刻まで、届いた行を調べる (0 = 調べていない)
    poll = false,      -- 今調べているのは見張りで打った分か
    sent_at = -100,    -- 見張りで打った時刻
    next_poll = 0,     -- 次に見張りで打つ時刻
    batch = {},        -- 見張りで今回届いた行 {name, body}
    last = nil,        -- 前回の見張りで届いた行の並び (比べるための文字列の一覧)
    misses = 0,        -- 続けて応答が無かった回数
    shown = 0, hidden = 0,
}

local function watch_interval()
    return math.max(WATCH_MIN_SEC, math.min(WATCH_MAX_SEC, tonumber(settings.watch_interval) or 120))
end

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

-- 知らせるときの本文: 定型文の印 [at]…[/at] を {…} に、&#34; のような書き方を元の文字に直す
local function clean_gw_body(body)
    body = body:gsub("%[at%]", "{"):gsub("%[/at%]", "}")
    body = body:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        return (n and n >= 32 and n < 127) and string.char(n) or ""
    end)
    body = body:gsub("[%z\1-\31\127]", " "):gsub("\\", "＼"):gsub("%${", "$ {")
    return body
end

-- 見張りで届く定型文は、Guildwork が英語で送ってくる ({Bazaar} など)。{…} の中を日本語に直す。
-- res の auto_translates.lua → items.lua の順に、1 行ずつ読んで英語名を探す (全部をメモリに載せない)。
-- 初めての言葉があるときだけ読み、結果は覚える。見つからない言葉は英語のまま残す。
local PHRASE_FILES = {"res/auto_translates.lua", "res/items.lua"}
local phrase_ja = {}   -- 小文字の英語 → 日本語 (見つからなかったものは false)

local function lookup_phrases(wanted)
    local base = windower.windower_path
    if type(base) == "string" then
        for _, rel in ipairs(PHRASE_FILES) do
            local f = io.open(base .. rel, "r")
            if f then
                for line in f:lines() do
                    local en, ja = line:match('{id=%d+,en="(.-)",ja="(.-)"')
                    if en then
                        local key = en:lower()
                        if wanted[key] and not phrase_ja[key] and ja ~= "" then phrase_ja[key] = ja end
                    end
                end
                f:close()
            end
        end
    end
    for key in pairs(wanted) do
        if not phrase_ja[key] then phrase_ja[key] = false end
    end
end

local function translate_phrases(body)
    local wanted, missing = {}, false
    for en in body:gmatch("{([^{}]+)}") do
        local key = en:lower()
        if phrase_ja[key] == nil then wanted[key] = true; missing = true end
    end
    if missing then lookup_phrases(wanted) end
    return (body:gsub("{([^{}]+)}", function(en)
        local ja = phrase_ja[en:lower()]
        if ja then return "{" .. ja .. "}" end
    end))
end

local function stop_watch(reason)
    settings.watch = false
    gw.last, gw.misses = nil, 0
    config.save(settings)
    if reason then chat_msg("[ShoutLog] " .. reason, 167) end
end

-- 見張りで届いた行を前回と比べ、増えた発言だけを知らせる
local function process_batch()
    local batch = gw.batch
    gw.batch = {}
    if #batch == 0 then
        gw.misses = gw.misses + 1
        if gw.misses >= GW_MAX_MISSES then
            stop_watch("Guildwork から応答が無いので、見張りを止めました。//load Guildwork と Guildwork へのログインを確かめてから //shl watch で始め直してください。")
        end
        return
    end
    gw.misses = 0
    local keys = {}
    for i, e in ipairs(batch) do keys[i] = e.name .. "\0" .. e.body end
    local old = gw.last
    gw.last = keys
    if not old then return end   -- 最初の 1 回は、今ある発言を覚えるだけ

    -- 行は古い順に届く。前回の後ろ側と今回の前側が重なるところを探し、その先を新しい発言とする
    local new_from = 1
    for j = 1, #old do
        local len = #old - j + 1
        if len <= #keys then
            local same = true
            for k = 1, len do
                if old[j + k - 1] ~= keys[k] then same = false; break end
            end
            if same then new_from = len + 1; break end
        end
    end

    local told = 0
    for i = new_from, #keys do
        local e = batch[i]
        -- 定型文は先に日本語にしてから比べる (定型文だけの発言は、日本語どうしでないと同じと分からない)
        local body = translate_phrases(clean_gw_body(e.body))
        -- 直接届いた発言 (自分のいるエリアのシャウト・届いたエール) は、もう見えているので知らせない
        if heard_directly(e.name, body) then
            gw.skipped_direct = (gw.skipped_direct or 0) + 1
        elseif not settings.japanese_only or is_wanted(e.name, e.body) then
            chat_msg(string.format("[遠くのシャウト] %s: %s", e.name, body), tonumber(settings.notify_mode) or 207)
            add_entry(MODE_GW, e.name, body)
            told = told + 1
        end
    end
    if told > 0 and settings.watch_sound and windower.file_exists and windower.file_exists(NOTIFY_SOUND) then
        windower.play_sound(NOTIFY_SOUND)
    end
end

windower.register_event("incoming text", function(original, modified, original_mode)
    if gw.until_at == 0 then return end
    if original_mode ~= GW_MODE and not (original_mode == GW_MODE_ALT and tostring(original or ""):find("^[%a%d_%-']+%[%?%?%?%]: ")) then
        return
    end
    if os.clock() > gw.until_at then return end
    local ok, name, body = pcall(parse_gw_line, original)
    if not ok or not name then return end
    if gw.poll then
        -- 見張りで打った分: 全部隠して、あとでまとめて比べる
        gw.batch[#gw.batch + 1] = {name = name, body = body}
        return true
    end
    if not (settings.gw_filter and settings.japanese_only) then return end
    if not is_wanted(name, body) then
        gw.hidden = gw.hidden + 1
        return true
    end
    gw.shown = gw.shown + 1
end)

-- 見張り: 待ち時間が過ぎた出力を片づけ、間隔が来たら「/gw shouts」を打つ。普段は時刻を比べるだけ
local function watch_tick(now)
    if gw.until_at ~= 0 and now > gw.until_at then
        local was_poll = gw.poll
        gw.until_at, gw.poll = 0, false
        if was_poll then process_batch() end
    end
    if not settings.watch or gw.until_at ~= 0 or now < gw.next_poll then return end
    gw.next_poll = now + watch_interval()
    local info = windower.ffxi.get_info()
    if not (info and info.logged_in) then return end
    gw.batch = {}
    gw.poll, gw.sent_at, gw.until_at = true, now, now + GW_POLL_WAIT_SEC
    windower.send_command("input /gw shouts")
end

windower.register_event("prerender", function()
    if not settings.watch and gw.until_at == 0 then return end
    local ok, err = pcall(watch_tick, os.clock())
    if not ok then report_error("見張りエラー", err) end
end)

-- 「/gw shouts」が打たれたとき: 自分で打った分なら上の絞り込みを始める。
-- 設定 gw_takeover がオンなら、代わりにこの窓を開く (発言はゲームに送らない)
windower.register_event("outgoing text", function(original)
    local is_shouts = tostring(original or ""):lower():find("^/gw%s+shout") ~= nil
    if is_shouts and os.clock() - gw.sent_at < 1.0 then return end   -- 見張りで打った分
    if is_shouts then
        gw.poll, gw.batch = false, {}
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
    gw.until_at, gw.poll, gw.batch, gw.last, gw.misses = 0, false, {}, nil, 0
    direct_heard = {}
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

    elseif cmd == "mode" and tonumber(args[1]) then
        -- 見張りの知らせを出すチャットの種類。どのログウィンドウに出るかは、ゲームのログの設定しだい
        settings.notify_mode = math.max(0, math.min(255, math.floor(tonumber(args[1]))))
        config.save(settings)
        chat_msg(string.format("[遠くのシャウト] 知らせの種類を %d にしました (この行がその見本です)。", settings.notify_mode), settings.notify_mode)

    elseif cmd == "modetest" then
        -- 種類ごとに 1 行ずつ出す。どの行がどのログウィンドウに出たかを見て、//shl mode <番号> で選ぶ
        local modes = {}
        for i = 1, #args do modes[#modes + 1] = tonumber(args[i]) end
        if #modes == 0 then modes = {207, 10, 11, 127, 121, 200, 8, 1} end
        for _, mode in ipairs(modes) do
            chat_msg(string.format("[ShoutLog] 種類 %d の見本", mode), mode)
        end

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
        if settings.watch then   -- 隠しコマンドなので、使っている人にだけ見せる
            chat_msg(string.format("[ShoutLog] 見張り: ON / 間隔 %d 秒 / 音 %s / 直接届いていたので知らせなかった発言 %d 件",
                watch_interval(), settings.watch_sound and "ON" or "OFF", gw.skipped_direct or 0))
        end

    elseif cmd == "watch" then
        -- //shl watch : 見張りの ON/OFF / //shl watch <秒> : 間隔 / //shl watch sound : 音の ON/OFF
        local sub = args[1] and args[1]:lower()
        if tonumber(sub) then
            settings.watch_interval = math.max(WATCH_MIN_SEC, math.min(WATCH_MAX_SEC, math.floor(tonumber(sub))))
            config.save(settings)
            chat_msg(string.format("[ShoutLog] 見張りの間隔を %d 秒にしました。", settings.watch_interval))
        elseif sub == "sound" then
            settings.watch_sound = not settings.watch_sound
            config.save(settings)
            chat_msg(string.format("[ShoutLog] 新しい発言の音: %s%s", settings.watch_sound and "ON" or "OFF",
                (windower.file_exists and not windower.file_exists(NOTIFY_SOUND)) and " (sounds/notify.wav がありません)" or ""))
        elseif settings.watch then
            stop_watch()
            chat_msg("[ShoutLog] 見張り: OFF")
        else
            settings.watch = true
            gw.last, gw.misses, gw.next_poll = nil, 0, os.clock() + 2
            config.save(settings)
            chat_msg(string.format("[ShoutLog] 見張り: ON (%d 秒ごとに Guildwork の発言を調べ、新しいものだけ知らせます)", watch_interval()))
        end

    elseif cmd == "gw" then
        settings.gw_takeover = not settings.gw_takeover
        config.save(settings)
        chat_msg(string.format("[ShoutLog] 「/gw shouts」でこの窓を開く: %s", settings.gw_takeover and "ON" or "OFF"))

    else
        -- 見張りのコマンド (watch・mode・modetest) は隠しコマンドなので、ここには出さない (冒頭のコメントを参照)
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
