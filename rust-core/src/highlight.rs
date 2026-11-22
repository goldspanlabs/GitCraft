use std::sync::OnceLock;

use crate::StyleSpan;
use syntect::{
    easy::HighlightLines, highlighting::ThemeSet, parsing::SyntaxSet, util::LinesWithEndings,
};

static SYNTAX_SET: OnceLock<SyntaxSet> = OnceLock::new();
static THEME_SET: OnceLock<ThemeSet> = OnceLock::new();

fn syntax_set() -> &'static SyntaxSet {
    SYNTAX_SET.get_or_init(SyntaxSet::load_defaults_newlines)
}

fn theme_set() -> &'static ThemeSet {
    THEME_SET.get_or_init(ThemeSet::load_defaults)
}

pub fn highlight(text: &str, extension: &str) -> Vec<StyleSpan> {
    let ss = syntax_set();
    let ts = theme_set();
    let syntax = ss
        .find_syntax_by_extension(extension)
        .unwrap_or_else(|| ss.find_syntax_plain_text());
    let mut highlighter = HighlightLines::new(syntax, &ts.themes["base16-ocean.dark"]);
    let mut offset = 0usize;
    let mut spans = Vec::new();
    for line in LinesWithEndings::from(text) {
        if let Ok(parts) = highlighter.highlight_line(line, ss) {
            for (style, token) in parts {
                let start_utf16 = text[..offset].encode_utf16().count();
                spans.push(StyleSpan {
                    start_utf16: start_utf16 as u32,
                    len_utf16: token.encode_utf16().count() as u32,
                    foreground: format!(
                        "#{:02x}{:02x}{:02x}",
                        style.foreground.r, style.foreground.g, style.foreground.b
                    ),
                });
                offset += token.len();
            }
        } else {
            offset += line.len();
        }
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reports_utf16_lengths() {
        let spans = highlight("é\n", "txt");
        assert!(spans.iter().any(|span| span.len_utf16 > 0));
    }
}
