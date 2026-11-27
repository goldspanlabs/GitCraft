use pulldown_cmark::{html, Options, Parser};

/// Renders CommonMark + GitHub-Flavored Markdown (tables, strikethrough, task lists)
/// into an HTML fragment for display in the preview pane.
pub fn render_html(markdown: &str) -> String {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_HEADING_ATTRIBUTES;
    let parser = Parser::new_ext(markdown, options);
    let mut out = String::with_capacity(markdown.len() * 2);
    html::push_html(&mut out, parser);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_headings_code_and_tables() {
        let md = "# Title\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```rust\nlet x = 1;\n```\n";
        let html = render_html(md);
        assert!(html.contains("<h1>Title</h1>"));
        assert!(html.contains("<table>"));
        assert!(html.contains("<td>1</td>"));
        assert!(html.contains("<code class=\"language-rust\">"));
    }

    #[test]
    fn renders_task_lists_and_strikethrough() {
        let md = "- [x] Done\n- [ ] ~~Todo~~\n";
        let html = render_html(md);
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("checked=\"\""));
        assert!(html.contains("<del>Todo</del>"));
    }
}
