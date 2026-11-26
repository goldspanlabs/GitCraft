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

pub struct LineHighlighter {
    inner: HighlightLines<'static>,
    syntax_set: &'static SyntaxSet,
}

impl LineHighlighter {
    pub fn new(extension: &str) -> Self {
        let ss = syntax_set();
        let ts = theme_set();
        let syntax = ss
            .find_syntax_by_extension(extension)
            .unwrap_or_else(|| ss.find_syntax_plain_text());
        let inner = HighlightLines::new(syntax, &ts.themes["base16-ocean.dark"]);
        Self {
            inner,
            syntax_set: ss,
        }
    }

    pub fn highlight_line(&mut self, line: &str) -> Vec<StyleSpan> {
        let Ok(parts) = self.inner.highlight_line(line, self.syntax_set) else {
            return Vec::new();
        };
        // Counted as the tokens go by: re-reading the line up to each token is quadratic.
        let mut start_utf16 = 0u32;
        let mut spans = Vec::with_capacity(parts.len());
        for (style, token) in parts {
            let len_utf16 = token.encode_utf16().count() as u32;
            spans.push(StyleSpan {
                start_utf16,
                len_utf16,
                foreground: format!(
                    "#{:02x}{:02x}{:02x}",
                    style.foreground.r, style.foreground.g, style.foreground.b
                ),
            });
            start_utf16 += len_utf16;
        }
        spans
    }
}

pub fn highlight(text: &str, extension: &str) -> Vec<StyleSpan> {
    let mut hl = LineHighlighter::new(extension);
    let mut offset = 0usize;
    let mut spans = Vec::new();
    for line in LinesWithEndings::from(text) {
        let line_start_utf16 = text[..offset].encode_utf16().count() as u32;
        for mut span in hl.highlight_line(line) {
            span.start_utf16 += line_start_utf16;
            spans.push(span);
        }
        offset += line.len();
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

    #[test]
    fn span_starts_count_utf16_units_of_the_text_before_them() {
        let spans = LineHighlighter::new("rs").highlight_line("let s = \"é😀\"; let n = 1;");
        let mut expected = 0;
        for span in &spans {
            assert_eq!(span.start_utf16, expected);
            expected += span.len_utf16;
        }
        assert_eq!(expected, 25);
    }
}
