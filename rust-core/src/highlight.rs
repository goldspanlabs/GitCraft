use crate::StyleSpan;
use syntect::{
    easy::HighlightLines, highlighting::ThemeSet, parsing::SyntaxSet, util::LinesWithEndings,
};

pub fn highlight(text: &str, extension: &str) -> Vec<StyleSpan> {
    let syntax_set = SyntaxSet::load_defaults_newlines();
    let theme_set = ThemeSet::load_defaults();
    let syntax = syntax_set
        .find_syntax_by_extension(extension)
        .unwrap_or_else(|| syntax_set.find_syntax_plain_text());
    let mut highlighter = HighlightLines::new(syntax, &theme_set.themes["base16-ocean.dark"]);
    let mut offset = 0usize;
    let mut spans = Vec::new();
    for line in LinesWithEndings::from(text) {
        if let Ok(parts) = highlighter.highlight_line(line, &syntax_set) {
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
