//! FTS5 BM25 keyword search, ported from `memweave/search/keyword.py`.
//!
//! Uses SQLite's built-in FTS5 extension and `bm25()` ranking function via
//! the `chunks_fts` table created by `storage/schema.zig`.

const std = @import("std");
const sqlite = @import("sqlite");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const schema = @import("../storage/schema.zig");

// ── Stop word sets ──────────────────────────────────────────────────────
// Mechanically extracted from keyword.py's seven `_STOP_WORDS_*` frozensets
// (ast.literal_eval + sorted), not hand-transcribed, to avoid transcription
// errors in non-ASCII data. Matched case-sensitively against already
// (ASCII-)lowercased tokens, same as the Python original.

const stop_words_en: []const []const u8 = &.{
    "a",
    "about",
    "above",
    "after",
    "ago",
    "an",
    "and",
    "anything",
    "are",
    "as",
    "at",
    "be",
    "because",
    "been",
    "before",
    "being",
    "below",
    "between",
    "but",
    "by",
    "can",
    "could",
    "did",
    "do",
    "does",
    "during",
    "earlier",
    "everything",
    "find",
    "for",
    "from",
    "get",
    "give",
    "had",
    "has",
    "have",
    "he",
    "help",
    "how",
    "i",
    "if",
    "in",
    "into",
    "is",
    "it",
    "just",
    "later",
    "may",
    "me",
    "might",
    "my",
    "nothing",
    "now",
    "of",
    "on",
    "or",
    "our",
    "over",
    "please",
    "recently",
    "she",
    "should",
    "show",
    "something",
    "stuff",
    "tell",
    "that",
    "the",
    "them",
    "then",
    "these",
    "they",
    "thing",
    "things",
    "this",
    "those",
    "through",
    "to",
    "today",
    "tomorrow",
    "under",
    "was",
    "we",
    "were",
    "what",
    "when",
    "where",
    "which",
    "while",
    "who",
    "why",
    "will",
    "with",
    "would",
    "yesterday",
    "you",
    "your",
};

const stop_words_es: []const []const u8 = &.{
    "a",
    "ahora",
    "antes",
    "ayer",
    "ayuda",
    "como",
    "con",
    "cuando",
    "cuándo",
    "cómo",
    "de",
    "del",
    "despues",
    "después",
    "donde",
    "dónde",
    "el",
    "ellas",
    "ellos",
    "en",
    "entre",
    "es",
    "esa",
    "ese",
    "esta",
    "estar",
    "este",
    "favor",
    "fue",
    "fueron",
    "haber",
    "hacer",
    "hoy",
    "la",
    "las",
    "los",
    "mañana",
    "me",
    "mi",
    "nosotras",
    "nosotros",
    "o",
    "para",
    "pero",
    "por",
    "porque",
    "porquê",
    "que",
    "qué",
    "recientemente",
    "ser",
    "si",
    "sobre",
    "son",
    "tener",
    "tu",
    "tus",
    "un",
    "una",
    "unas",
    "unos",
    "usted",
    "ustedes",
    "y",
    "yo",
};

const stop_words_pt: []const []const u8 = &.{
    "a",
    "agora",
    "ajuda",
    "amanhã",
    "antes",
    "as",
    "com",
    "como",
    "da",
    "de",
    "depois",
    "do",
    "e",
    "ela",
    "elas",
    "ele",
    "eles",
    "em",
    "entre",
    "essa",
    "esse",
    "esta",
    "estar",
    "este",
    "eu",
    "favor",
    "fazer",
    "foi",
    "foram",
    "hoje",
    "mas",
    "me",
    "meu",
    "minha",
    "nos",
    "nós",
    "o",
    "onde",
    "ontem",
    "os",
    "ou",
    "para",
    "por",
    "porque",
    "porquê",
    "quando",
    "que",
    "quê",
    "recentemente",
    "se",
    "ser",
    "sobre",
    "são",
    "ter",
    "um",
    "uma",
    "umas",
    "uns",
    "você",
    "vocês",
    "é",
};

const stop_words_ar: []const []const u8 = &.{
    "أصبح",
    "أنا",
    "أو",
    "أين",
    "إلى",
    "ال",
    "الآن",
    "الى",
    "اليوم",
    "امس",
    "ب",
    "بالأمس",
    "بعد",
    "بل",
    "بين",
    "تكون",
    "تلك",
    "ثم",
    "ذلك",
    "ساعد",
    "صار",
    "على",
    "عن",
    "غدا",
    "فضلا",
    "في",
    "قبل",
    "ك",
    "كان",
    "كانت",
    "كيف",
    "ل",
    "لكن",
    "لماذا",
    "مؤخرا",
    "ماذا",
    "متى",
    "مع",
    "ممكن",
    "من",
    "من فضلك",
    "نحن",
    "هذا",
    "هذه",
    "هل",
    "هم",
    "هنا",
    "هناك",
    "هو",
    "هي",
    "و",
    "يكون",
    "يمكن",
};

const stop_words_ko: []const []const u8 = &.{
    "가",
    "가다",
    "같이",
    "거",
    "거기",
    "것",
    "곳",
    "과",
    "그",
    "그것",
    "그녀",
    "그들",
    "그래서",
    "그러나",
    "그러면",
    "그런데",
    "그리고",
    "까지",
    "께",
    "나",
    "나는",
    "나를",
    "나중",
    "내가",
    "내일",
    "너",
    "너무",
    "누구",
    "는",
    "대로",
    "더",
    "도",
    "되다",
    "등",
    "때",
    "또",
    "또는",
    "로",
    "를",
    "마다",
    "만",
    "많이",
    "매우",
    "무엇",
    "뭐",
    "밖에",
    "보다",
    "부탁",
    "부터",
    "분",
    "수",
    "아까",
    "아니다",
    "아주",
    "어디",
    "어떤",
    "어떻게",
    "어제",
    "언제",
    "없다",
    "에",
    "에게",
    "에서",
    "여기",
    "오늘",
    "오다",
    "와",
    "왜",
    "우리",
    "으로",
    "은",
    "을",
    "의",
    "이",
    "이것",
    "이다",
    "있다",
    "잘",
    "저",
    "저것",
    "저기",
    "저희",
    "전에",
    "정말",
    "제발",
    "좀",
    "주다",
    "중",
    "지금",
    "처럼",
    "최근",
    "하다",
    "하지만",
    "한테",
};

const stop_words_ja: []const []const u8 = &.{
    "あそこ",
    "あの",
    "ある",
    "あれ",
    "いつ",
    "いる",
    "から",
    "ここ",
    "こと",
    "この",
    "これ",
    "さっき",
    "しかし",
    "した",
    "して",
    "する",
    "そこ",
    "そして",
    "その",
    "それ",
    "ため",
    "だけ",
    "できる",
    "です",
    "でも",
    "どう",
    "どこ",
    "どれ",
    "なぜ",
    "なる",
    "の",
    "ます",
    "また",
    "まで",
    "もの",
    "より",
    "今",
    "今日",
    "何",
    "前",
    "後",
    "明日",
    "昨日",
    "最近",
    "誰",
};

const stop_words_zh: []const []const u8 = &.{
    "与",
    "东西",
    "为什么",
    "之前",
    "之后",
    "也",
    "了",
    "事",
    "事情",
    "什么",
    "今天",
    "他",
    "他们",
    "以前",
    "以后",
    "会",
    "但",
    "但是",
    "你",
    "你们",
    "做",
    "再",
    "刚才",
    "到",
    "去",
    "又",
    "只",
    "可以",
    "吗",
    "吧",
    "呀",
    "告诉",
    "呢",
    "和",
    "哪个",
    "哪些",
    "啊",
    "啦",
    "嘛",
    "因为",
    "在",
    "地",
    "多少",
    "她",
    "如果",
    "它",
    "就",
    "帮",
    "帮忙",
    "得",
    "怎么",
    "想",
    "我",
    "我们",
    "或",
    "所以",
    "才",
    "找",
    "把",
    "明天",
    "昨天",
    "是",
    "最近",
    "有",
    "来",
    "现在",
    "用",
    "的",
    "看",
    "着",
    "给",
    "而",
    "能",
    "虽然",
    "被",
    "要",
    "让",
    "说",
    "请",
    "过",
    "还",
    "这",
    "这个",
    "这些",
    "那",
    "那个",
    "那些",
    "都",
};

fn containsStr(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Return `true` if `token` is a stop word in any of the seven supported
/// languages (EN/ES/PT/AR/ZH/KO/JA). Case-sensitive — English callers should
/// lowercase first, matching the Python original.
pub fn isStopWord(token: []const u8) bool {
    return containsStr(stop_words_en, token) or
        containsStr(stop_words_es, token) or
        containsStr(stop_words_pt, token) or
        containsStr(stop_words_ar, token) or
        containsStr(stop_words_zh, token) or
        containsStr(stop_words_ko, token) or
        containsStr(stop_words_ja, token);
}

// ── Tokenization ─────────────────────────────────────────────────────────
//
// Python tokenizes with `re.compile(r"[\w]+", re.UNICODE)`, matching any
// Unicode letter/digit/underscore. Zig's std has no Unicode category
// tables, so this approximates it: any byte >= 0x80 (a UTF-8 continuation
// or lead byte — never ASCII punctuation/whitespace) is treated as a word
// byte alongside ASCII alphanumerics and `_`. This covers the common case
// (non-ASCII scripts are all >= 0x80 in UTF-8) without a full Unicode
// category table; it does not replicate Python's handling of, e.g.,
// combining marks or Unicode punctuation as separators within a script.

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Split `text` into word tokens (see the tokenization note above). Returns
/// a caller-owned slice of slices into `text` (no copies of the bytes
/// themselves).
pub fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (isWordByte(text[i])) {
            const start = i;
            while (i < text.len and isWordByte(text[i])) : (i += 1) {}
            try tokens.append(allocator, text[start..i]);
        } else {
            i += 1;
        }
    }
    return tokens.toOwnedSlice(allocator);
}

/// Convert a raw user query into a safe FTS5 MATCH expression (mirrors
/// `build_fts_query`): tokenize, quote each token (stripping embedded `"`),
/// join with ` AND `. Returns `null` if the query yields no tokens.
pub fn buildFtsQuery(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const tokens = try tokenize(allocator, raw);
    defer allocator.free(tokens);
    if (tokens.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (tokens, 0..) |t, i| {
        if (i != 0) try buf.appendSlice(allocator, " AND ");
        try buf.append(allocator, '"');
        for (t) |c| {
            if (c != '"') try buf.append(allocator, c);
        }
        try buf.append(allocator, '"');
    }
    return try buf.toOwnedSlice(allocator);
}

/// Convert an FTS5 `bm25()` rank to a normalized relevance score in (0, 1]
/// (mirrors `bm25_rank_to_score`). FTS5 BM25 ranks are negative for
/// matches — more negative is more relevant.
pub fn bm25RankToScore(rank: f64) f64 {
    if (!std.math.isFinite(rank)) return 1.0 / (1.0 + 999.0);
    if (rank < 0) {
        const relevance = -rank;
        return relevance / (1.0 + relevance);
    }
    return 1.0 / (1.0 + rank);
}

/// Return `true` if `token` is a meaningful search keyword (mirrors
/// `_is_valid_keyword`): not empty, not a short pure-ASCII-alpha fragment
/// (< 3 chars), not pure digits. The Python original also rejects tokens
/// matching `^\W+$`, but since callers only pass tokens already matched by
/// the `\w+` tokenizer, that branch is unreachable there too — omitted here
/// for the same reason.
fn isValidKeyword(token: []const u8) bool {
    if (token.len == 0) return false;

    var all_ascii_alpha = true;
    for (token) |c| {
        if (!std.ascii.isAlphabetic(c)) {
            all_ascii_alpha = false;
            break;
        }
    }
    if (all_ascii_alpha and token.len < 3) return false;

    var all_digit = true;
    for (token) |c| {
        if (!std.ascii.isDigit(c)) {
            all_digit = false;
            break;
        }
    }
    if (all_digit) return false;

    return true;
}

/// Extract meaningful, deduplicated keywords from a query (mirrors
/// `extract_keywords`): tokenize, drop stop words (checked both as-is and
/// ASCII-lowercased) and invalid keywords, dedupe by ASCII-lowercased form
/// while preserving first-seen order and original casing.
pub fn extractKeywords(allocator: std.mem.Allocator, query: []const u8) ![][]const u8 {
    const raw_tokens = try tokenize(allocator, query);
    defer allocator.free(raw_tokens);

    var keywords: std.ArrayList([]const u8) = .empty;
    errdefer keywords.deinit(allocator);

    var seen_lower: std.ArrayList([]u8) = .empty;
    defer {
        for (seen_lower.items) |s| allocator.free(s);
        seen_lower.deinit(allocator);
    }

    for (raw_tokens) |raw_token| {
        const lower_buf = try allocator.alloc(u8, raw_token.len);
        const lower = std.ascii.lowerString(lower_buf, raw_token);

        if (isStopWord(lower) or isStopWord(raw_token)) {
            allocator.free(lower_buf);
            continue;
        }
        if (!isValidKeyword(raw_token)) {
            allocator.free(lower_buf);
            continue;
        }

        var already_seen = false;
        for (seen_lower.items) |s| {
            if (std.mem.eql(u8, s, lower)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) {
            allocator.free(lower_buf);
            continue;
        }

        try seen_lower.append(allocator, lower_buf);
        try keywords.append(allocator, raw_token);
    }
    return keywords.toOwnedSlice(allocator);
}

// ── KeywordSearch backend ────────────────────────────────────────────────

const FtsRow = struct {
    id: []const u8,
    path: []const u8,
    source: []const u8,
    start_line: i64,
    end_line: i64,
    text: []const u8,
    rank: f64,
};

/// Run an FTS5 BM25 keyword search against `chunks_fts` (mirrors
/// `KeywordSearch.search`). Returns an empty slice if `query` yields no
/// tokens or no rows match.
pub fn search(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    query: []const u8,
    model: []const u8,
    limit: i64,
    source_filter: ?[]const u8,
) errors.SearchError![]types.RawSearchRow {
    const maybe_fts_query: ?[]const u8 = buildFtsQuery(allocator, query) catch return error.SearchError;
    const fts_query = maybe_fts_query orelse {
        return allocator.alloc(types.RawSearchRow, 0) catch return error.SearchError;
    };
    defer allocator.free(fts_query);

    const fts_rows: []FtsRow = if (source_filter) |sf| blk: {
        var stmt = db.prepare(
            "SELECT id, path, source, start_line, end_line, text, bm25(chunks_fts) AS rank" ++
                " FROM chunks_fts WHERE chunks_fts MATCH ?{[]const u8} AND model = ?{[]const u8} AND source = ?{[]const u8}" ++
                " ORDER BY rank ASC LIMIT ?{i64}",
        ) catch return error.SearchError;
        defer stmt.deinit();
        break :blk stmt.all(FtsRow, allocator, .{}, .{ fts_query, model, sf, limit }) catch return error.SearchError;
    } else blk: {
        var stmt = db.prepare(
            "SELECT id, path, source, start_line, end_line, text, bm25(chunks_fts) AS rank" ++
                " FROM chunks_fts WHERE chunks_fts MATCH ?{[]const u8} AND model = ?{[]const u8}" ++
                " ORDER BY rank ASC LIMIT ?{i64}",
        ) catch return error.SearchError;
        defer stmt.deinit();
        break :blk stmt.all(FtsRow, allocator, .{}, .{ fts_query, model, limit }) catch return error.SearchError;
    };
    defer allocator.free(fts_rows);

    var out = allocator.alloc(types.RawSearchRow, fts_rows.len) catch return error.SearchError;
    for (fts_rows, 0..) |r, i| {
        const score = bm25RankToScore(r.rank);
        out[i] = .{
            .chunk_id = r.id,
            .path = r.path,
            .source = r.source,
            .start_line = @intCast(r.start_line),
            .end_line = @intCast(r.end_line),
            .text = r.text,
            .score = score,
            .vector_score = null,
            .text_score = score,
        };
    }
    return out;
}

// ── Tests — golden values obtained by running the real Python
// implementation directly in this session (bypassing the package's
// importlib.metadata version lookup), not just reasoning about the
// source. ──────────────────────────────────────────────────────────────

test "bm25RankToScore matches the Python reference for representative ranks" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.8076923076923077), bm25RankToScore(-4.2), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3333333333333333), bm25RankToScore(-0.5), 1e-12);
    try std.testing.expectEqual(@as(f64, 1.0), bm25RankToScore(0.0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.16666666666666666), bm25RankToScore(5.0), 1e-12);
    try std.testing.expectEqual(@as(f64, 0.001), bm25RankToScore(std.math.nan(f64)));
}

test "buildFtsQuery matches the Python reference" {
    const a = try buildFtsQuery(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(a.?);
    try std.testing.expectEqualStrings("\"hello\" AND \"world\"", a.?);

    const b = try buildFtsQuery(std.testing.allocator, "FOO_bar baz-1");
    defer std.testing.allocator.free(b.?);
    try std.testing.expectEqualStrings("\"FOO_bar\" AND \"baz\" AND \"1\"", b.?);

    const c = try buildFtsQuery(std.testing.allocator, "???");
    try std.testing.expectEqual(@as(?[]u8, null), c);

    const d = try buildFtsQuery(std.testing.allocator, "say \"hi\" now");
    defer std.testing.allocator.free(d.?);
    try std.testing.expectEqualStrings("\"say\" AND \"hi\" AND \"now\"", d.?);
}

test "extractKeywords matches the Python reference" {
    const a = try extractKeywords(std.testing.allocator, "which database did we pick?");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("database", a[0]);
    try std.testing.expectEqualStrings("pick", a[1]);

    const b = try extractKeywords(std.testing.allocator, "PostgreSQL connection pooling");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(usize, 3), b.len);
    try std.testing.expectEqualStrings("PostgreSQL", b[0]);
    try std.testing.expectEqualStrings("connection", b[1]);
    try std.testing.expectEqualStrings("pooling", b[2]);

    // "the" (stop word), "ab"/"cd" (short ASCII fragments), "123" (pure
    // digits) are all filtered — matches the real Python behavior exactly,
    // including that this yields an empty result.
    const c = try extractKeywords(std.testing.allocator, "the ab cd 123 the");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqual(@as(usize, 0), c.len);
}

test "isStopWord covers all seven languages" {
    try std.testing.expect(isStopWord("the"));
    try std.testing.expect(isStopWord("como"));
    try std.testing.expect(isStopWord("é"));
    try std.testing.expect(isStopWord("من"));
    try std.testing.expect(isStopWord("는"));
    try std.testing.expect(isStopWord("これ"));
    try std.testing.expect(isStopWord("的"));
    try std.testing.expect(!isStopWord("postgresql"));
}

fn testDb() !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    try schema.ensureSchema(&db);
    return db;
}

test "search finds matching chunks and ranks by relevance, filtered by model and source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = try testDb();
    defer db.deinit();

    const model: []const u8 = "text-embedding-3-small";
    const rows_to_insert = [_]struct { id: []const u8, path: []const u8, source: []const u8, text: []const u8 }{
        .{ .id = "c1", .path = "memory/a.md", .source = "memory", .text = "PostgreSQL connection pooling is great" },
        .{ .id = "c2", .path = "memory/b.md", .source = "memory", .text = "PostgreSQL is a database" },
        .{ .id = "c3", .path = "sessions/c.md", .source = "sessions", .text = "PostgreSQL session notes" },
        .{ .id = "c4", .path = "memory/d.md", .source = "memory", .text = "completely unrelated content about cats" },
    };
    for (rows_to_insert) |r| {
        db.exec(
            "INSERT INTO chunks_fts (text, id, path, source, model, start_line, end_line) VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{i64}, ?{i64})",
            .{},
            .{ r.text, r.id, r.path, r.source, model, @as(i64, 1), @as(i64, 1) },
        ) catch return error.SearchError;
    }

    const results = try search(allocator, &db, "PostgreSQL", model, 10, null);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    for (results) |r| {
        try std.testing.expect(r.score > 0.0);
        try std.testing.expect(r.text_score != null);
        try std.testing.expect(r.vector_score == null);
    }

    const memory_only = try search(allocator, &db, "PostgreSQL", model, 10, "memory");
    try std.testing.expectEqual(@as(usize, 2), memory_only.len);
    for (memory_only) |r| try std.testing.expectEqualStrings("memory", r.source);

    const no_tokens = try search(allocator, &db, "???", model, 10, null);
    try std.testing.expectEqual(@as(usize, 0), no_tokens.len);
}
