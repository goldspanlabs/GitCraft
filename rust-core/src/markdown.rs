use pulldown_cmark::{html, Event, Options, Parser};

/// Renders CommonMark + GitHub-Flavored Markdown (tables, strikethrough, task lists)
/// into an HTML fragment for display in the preview pane.
pub fn render_html(markdown: &str) -> String {
    let options = markdown_options();
    let parser = Parser::new_ext(markdown, options);
    let mut out = String::with_capacity(markdown.len() * 2);
    html::push_html(&mut out, parser);
    out
}

/// Renders a block-level rich diff between `old_markdown` and `new_markdown` as an HTML fragment.
/// Unchanged blocks render normally; removed blocks are wrapped in `.diff-deleted` and added
/// blocks in `.diff-added`.
pub fn render_diff_html(old_markdown: Option<&str>, new_markdown: Option<&str>) -> String {
    match (old_markdown, new_markdown) {
        (None, None) => String::new(),
        (None, Some(new_md)) => {
            let blocks = render_blocks(new_md);
            wrap_all(&blocks, "diff-added")
        }
        (Some(old_md), None) => {
            let blocks = render_blocks(old_md);
            wrap_all(&blocks, "diff-deleted")
        }
        (Some(old_md), Some(new_md)) => {
            if old_md == new_md {
                return render_html(new_md);
            }
            let old_blocks = render_blocks(old_md);
            let new_blocks = render_blocks(new_md);
            diff_blocks_html(&old_blocks, &new_blocks)
        }
    }
}

fn markdown_options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_HEADING_ATTRIBUTES
}

fn render_blocks(markdown: &str) -> Vec<String> {
    let parser = Parser::new_ext(markdown, markdown_options());
    let mut blocks = Vec::new();
    let mut current: Vec<Event<'_>> = Vec::new();
    let mut depth: usize = 0;

    for event in parser {
        match &event {
            Event::Start(_) => {
                depth += 1;
                current.push(event);
            }
            Event::End(_) => {
                current.push(event);
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    blocks.push(events_to_html(std::mem::take(&mut current)));
                }
            }
            _ => {
                if depth == 0 {
                    blocks.push(events_to_html(vec![event]));
                } else {
                    current.push(event);
                }
            }
        }
    }

    if !current.is_empty() {
        blocks.push(events_to_html(current));
    }
    blocks
}

fn events_to_html(events: Vec<Event<'_>>) -> String {
    let mut out = String::new();
    html::push_html(&mut out, events.into_iter());
    out
}

fn wrap_all(blocks: &[String], class_name: &str) -> String {
    let mut out = String::new();
    for block in blocks {
        out.push_str("<div class=\"diff-block ");
        out.push_str(class_name);
        out.push_str("\">");
        out.push_str(block);
        out.push_str("</div>\n");
    }
    out
}

const MAX_LCS_BLOCKS: usize = 1500;

fn diff_blocks_html(old: &[String], new: &[String]) -> String {
    if old.len() > MAX_LCS_BLOCKS || new.len() > MAX_LCS_BLOCKS {
        let mut out = wrap_all(old, "diff-deleted");
        out.push_str(&wrap_all(new, "diff-added"));
        return out;
    }

    let n = old.len();
    let m = new.len();
    let mut dp = vec![0usize; (n + 1) * (m + 1)];
    let stride = m + 1;

    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i * stride + j] = if old[i] == new[j] {
                1 + dp[(i + 1) * stride + (j + 1)]
            } else {
                dp[(i + 1) * stride + j].max(dp[i * stride + (j + 1)])
            };
        }
    }

    let mut out = String::new();
    let mut i = 0;
    let mut j = 0;
    while i < n && j < m {
        if old[i] == new[j] {
            out.push_str(&new[j]);
            i += 1;
            j += 1;
        } else if dp[(i + 1) * stride + j] >= dp[i * stride + (j + 1)] {
            out.push_str("<div class=\"diff-block diff-deleted\">");
            out.push_str(&old[i]);
            out.push_str("</div>\n");
            i += 1;
        } else {
            out.push_str("<div class=\"diff-block diff-added\">");
            out.push_str(&new[j]);
            out.push_str("</div>\n");
            j += 1;
        }
    }
    while i < n {
        out.push_str("<div class=\"diff-block diff-deleted\">");
        out.push_str(&old[i]);
        out.push_str("</div>\n");
        i += 1;
    }
    while j < m {
        out.push_str("<div class=\"diff-block diff-added\">");
        out.push_str(&new[j]);
        out.push_str("</div>\n");
        j += 1;
    }
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

    #[test]
    fn diff_html_marks_added_and_deleted_blocks_around_unchanged_ones() {
        let old = "# Title\n\nOld paragraph.\n\nKeep me.\n";
        let new = "# Title\n\nNew paragraph.\n\nKeep me.\n";
        let html = render_diff_html(Some(old), Some(new));

        assert!(html.contains("<h1>Title</h1>"));
        assert!(!html.contains("diff-deleted\"><h1>Title</h1>"));
        assert!(
            html.contains("<div class=\"diff-block diff-deleted\"><p>Old paragraph.</p>\n</div>")
        );
        assert!(html.contains("<div class=\"diff-block diff-added\"><p>New paragraph.</p>\n</div>"));
        assert!(html.contains("<p>Keep me.</p>"));
    }

    #[test]
    fn diff_html_handles_new_and_deleted_files() {
        let added = render_diff_html(None, Some("# Fresh\n"));
        assert!(added.contains("<div class=\"diff-block diff-added\"><h1>Fresh</h1>\n</div>"));

        let deleted = render_diff_html(Some("# Gone\n"), None);
        assert!(deleted.contains("<div class=\"diff-block diff-deleted\"><h1>Gone</h1>\n</div>"));
    }
}
