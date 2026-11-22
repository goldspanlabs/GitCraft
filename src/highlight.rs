use std::path::Path;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TokenKind { Plain, Comment, String, Number, Keyword, Punctuation }

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Token { pub kind: TokenKind, pub text: String }

pub type HighlightToken = Token;

/// Lightweight source highlighter suitable for displaying diffs without a
/// parser or runtime grammar database.
pub fn highlight(source: &str, language: Option<&str>) -> Vec<Token> {
    let lang = language.or_else(|| Some("")).unwrap_or("").to_ascii_lowercase();
    let keywords = if ["rust", "rs"].contains(&lang.as_str()) {
        ["fn","let","mut","pub","struct","enum","impl","trait","use","mod","match","if","else","for","while","return","true","false"].as_slice()
    } else {
        ["fn","let","const","function","class","return","if","else","for","while","true","false","import","from"].as_slice()
    };
    let mut out = Vec::new();
    let mut word = String::new();
    let flush = |out: &mut Vec<Token>, word: &mut String, keywords: &[&str]| {
        if word.is_empty() { return; }
        let kind = if keywords.contains(&word.as_str()) { TokenKind::Keyword }
            else if word.chars().all(|c| c.is_ascii_digit()) { TokenKind::Number } else { TokenKind::Plain };
        out.push(Token { kind, text: std::mem::take(word) });
    };
    let chars: Vec<char> = source.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '"' || chars[i] == '\'' {
            flush(&mut out, &mut word, keywords);
            let quote = chars[i]; let start = i; i += 1;
            while i < chars.len() { if chars[i] == '\\' { i += 2; continue; } let end = chars[i] == quote; i += 1; if end { break; } }
            out.push(Token { kind: TokenKind::String, text: chars[start..i.min(chars.len())].iter().collect() });
        } else if chars[i] == '/' && chars.get(i + 1) == Some(&'/') || chars[i] == '#' {
            flush(&mut out, &mut word, keywords);
            out.push(Token { kind: TokenKind::Comment, text: chars[i..].iter().collect() }); break;
        } else if chars[i].is_ascii_alphanumeric() || chars[i] == '_' {
            word.push(chars[i]); i += 1;
        } else {
            flush(&mut out, &mut word, keywords);
            let kind = if chars[i].is_ascii_punctuation() { TokenKind::Punctuation } else { TokenKind::Plain };
            out.push(Token { kind, text: chars[i].to_string() }); i += 1;
        }

        pub fn highlight_code(source: &str, language: Option<&str>) -> Vec<Token> {
            highlight(source, language)
        }
    }
    flush(&mut out, &mut word, keywords);
    out
}

pub fn language_for_path(path: impl AsRef<Path>) -> Option<&'static str> {
    match path.as_ref().extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "rs" => Some("rust"), "js" | "jsx" | "ts" | "tsx" => Some("javascript"),
        "py" => Some("python"), "json" => Some("json"), "toml" => Some("toml"),
        "md" => Some("markdown"), _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recognizes_keywords_strings_and_comments() {
        let t = highlight("let x = \"ok\" // note", Some("rust"));
        assert!(t.iter().any(|x| x.kind == TokenKind::Keyword));
        assert!(t.iter().any(|x| x.kind == TokenKind::String));
        assert_eq!(t.last().unwrap().kind, TokenKind::Comment);
    }
}
