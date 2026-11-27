use std::sync::OnceLock;

use crate::StyleSpan;
use syntect::{
    easy::HighlightLines,
    highlighting::{Theme, ThemeSet},
    parsing::SyntaxSet,
    util::LinesWithEndings,
};

static SYNTAX_SET: OnceLock<SyntaxSet> = OnceLock::new();
static THEME: OnceLock<Theme> = OnceLock::new();

fn syntax_set() -> &'static SyntaxSet {
    SYNTAX_SET.get_or_init(SyntaxSet::load_defaults_newlines)
}

fn theme() -> &'static Theme {
    THEME.get_or_init(|| {
        ThemeSet::load_defaults()
            .themes
            .remove("base16-ocean.dark")
            .expect("default syntect themes include base16-ocean.dark")
    })
}

fn default_foreground_rgb(theme: &Theme) -> u32 {
    theme.settings.foreground.map_or(0, |fg| {
        ((fg.r as u32) << 16) | ((fg.g as u32) << 8) | (fg.b as u32)
    })
}

enum HighlighterKind {
    Syntax {
        inner: Box<HighlightLines<'static>>,
        syntax_set: &'static SyntaxSet,
    },
    PlainText {
        foreground: u32,
    },
}

pub struct LineHighlighter {
    kind: HighlighterKind,
}

impl LineHighlighter {
    pub fn new(extension: &str) -> Self {
        let ss = syntax_set();
        let t = theme();
        let kind = match ss.find_syntax_by_extension(extension) {
            Some(syntax) => HighlighterKind::Syntax {
                inner: Box::new(HighlightLines::new(syntax, t)),
                syntax_set: ss,
            },
            None => HighlighterKind::PlainText {
                foreground: default_foreground_rgb(t),
            },
        };
        Self { kind }
    }

    pub fn highlight_line(&mut self, line: &str) -> Vec<StyleSpan> {
        match &mut self.kind {
            HighlighterKind::PlainText { foreground } => {
                let len_utf16 = line.encode_utf16().count() as u32;
                if len_utf16 == 0 {
                    return Vec::new();
                }
                vec![StyleSpan {
                    start_utf16: 0,
                    len_utf16,
                    foreground: *foreground,
                }]
            }
            HighlighterKind::Syntax { inner, syntax_set } => {
                let Ok(parts) = inner.highlight_line(line, syntax_set) else {
                    return Vec::new();
                };
                // Counted as the tokens go by: re-reading the line up to each token is quadratic.
                let mut start_utf16 = 0u32;
                let mut spans: Vec<StyleSpan> = Vec::with_capacity(parts.len());
                for (style, token) in parts {
                    let len_utf16 = token.encode_utf16().count() as u32;
                    if len_utf16 == 0 {
                        continue;
                    }
                    let foreground = ((style.foreground.r as u32) << 16)
                        | ((style.foreground.g as u32) << 8)
                        | (style.foreground.b as u32);
                    if let Some(last) = spans.last_mut() {
                        if last.foreground == foreground
                            && last.start_utf16 + last.len_utf16 == start_utf16
                        {
                            last.len_utf16 += len_utf16;
                            start_utf16 += len_utf16;
                            continue;
                        }
                    }
                    spans.push(StyleSpan {
                        start_utf16,
                        len_utf16,
                        foreground,
                    });
                    start_utf16 += len_utf16;
                }
                spans
            }
        }
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
            assert!(span.foreground <= 0xFF_FFFF);
            expected += span.len_utf16;
        }
        assert_eq!(expected, 25);
    }

    #[test]
    fn adjacent_same_color_tokens_are_coalesced() {
        let spans = LineHighlighter::new("txt").highlight_line("hello   world   again");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].start_utf16, 0);
        assert_eq!(spans[0].len_utf16, 21);
    }
}
