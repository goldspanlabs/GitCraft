use std::collections::HashMap;

use pulldown_cmark::{html, CowStr, Event, Options, Parser, Tag, TagEnd};

/// Renders CommonMark + GitHub-Flavored Markdown (tables, strikethrough, task lists)
/// into an HTML fragment for display in the preview pane.
pub fn render_html(markdown: &str) -> String {
    let events = assign_heading_ids(Parser::new_ext(markdown, markdown_options()));
    events_to_html(events)
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

struct PendingHeading<'a> {
    level: pulldown_cmark::HeadingLevel,
    id: Option<CowStr<'a>>,
    classes: Vec<CowStr<'a>>,
    attrs: Vec<(CowStr<'a>, Option<CowStr<'a>>)>,
    inner: Vec<Event<'a>>,
}

/// Assigns GitHub-style deduplicated `id` attributes to headings that lack an explicit ID so
/// table-of-contents links (e.g. `[Features](#features)`) scroll to the matching heading.
fn assign_heading_ids<'a>(parser: impl Iterator<Item = Event<'a>>) -> Vec<Event<'a>> {
    let mut out = Vec::new();
    let mut slug_counts: HashMap<String, usize> = HashMap::new();
    let mut heading_buf: Option<PendingHeading<'a>> = None;

    for event in parser {
        if let Some(mut pending) = heading_buf.take() {
            match event {
                Event::End(TagEnd::Heading(end_level)) => {
                    let resolved_id = pending.id.or_else(|| {
                        let text = collect_plain_text(&pending.inner);
                        let base = github_slug(&text);
                        if base.is_empty() {
                            return None;
                        }
                        let count = slug_counts.entry(base.clone()).or_insert(0);
                        let unique = if *count == 0 {
                            base
                        } else {
                            format!("{base}-{count}")
                        };
                        *count += 1;
                        Some(CowStr::Boxed(unique.into_boxed_str()))
                    });
                    out.push(Event::Start(Tag::Heading {
                        level: pending.level,
                        id: resolved_id,
                        classes: pending.classes,
                        attrs: pending.attrs,
                    }));
                    out.append(&mut pending.inner);
                    out.push(Event::End(TagEnd::Heading(end_level)));
                }
                other => {
                    pending.inner.push(other);
                    heading_buf = Some(pending);
                }
            }
        } else if let Event::Start(Tag::Heading {
            level,
            id,
            classes,
            attrs,
        }) = event
        {
            heading_buf = Some(PendingHeading {
                level,
                id,
                classes,
                attrs,
                inner: Vec::new(),
            });
        } else {
            out.push(event);
        }
    }

    if let Some(mut pending) = heading_buf {
        out.push(Event::Start(Tag::Heading {
            level: pending.level,
            id: pending.id,
            classes: pending.classes,
            attrs: pending.attrs,
        }));
        out.append(&mut pending.inner);
    }

    out
}

fn collect_plain_text(events: &[Event<'_>]) -> String {
    let mut text = String::new();
    for ev in events {
        match ev {
            Event::Text(t) | Event::Code(t) => text.push_str(t),
            Event::SoftBreak | Event::HardBreak => text.push(' '),
            _ => {}
        }
    }
    text
}

fn github_slug(text: &str) -> String {
    let mut slug = String::with_capacity(text.len());
    for ch in text.trim().chars() {
        if ch.is_alphanumeric() || ch == '_' || ch == '-' {
            for lower in ch.to_lowercase() {
                slug.push(lower);
            }
        } else if ch == ' ' {
            slug.push('-');
        }
    }
    slug
}

fn render_blocks(markdown: &str) -> Vec<String> {
    let events = assign_heading_ids(Parser::new_ext(markdown, markdown_options()));
    let mut blocks = Vec::new();
    let mut current: Vec<Event<'_>> = Vec::new();
    let mut depth: usize = 0;
    let mut html_depth: usize = 0;

    for event in events {
        match &event {
            Event::Start(_) => {
                depth += 1;
                current.push(event);
            }
            Event::End(_) => {
                current.push(event);
                depth = depth.saturating_sub(1);
                if depth == 0 && html_depth == 0 {
                    blocks.push(events_to_html(std::mem::take(&mut current)));
                }
            }
            Event::Html(raw) | Event::InlineHtml(raw) => {
                html_depth = update_html_depth(html_depth, raw);
                current.push(event);
                if depth == 0 && html_depth == 0 {
                    blocks.push(events_to_html(std::mem::take(&mut current)));
                }
            }
            _ => {
                if depth == 0 && html_depth == 0 {
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

fn update_html_depth(mut depth: usize, raw: &str) -> usize {
    let mut rest = raw;
    while let Some(lt) = rest.find('<') {
        rest = &rest[lt + 1..];
        if rest.starts_with("!--") {
            if let Some(end) = rest.find("-->") {
                rest = &rest[end + 3..];
                continue;
            }
            break;
        }
        let Some(gt) = rest.find('>') else {
            break;
        };
        let tag_inner = rest[..gt].trim();
        rest = &rest[gt + 1..];
        if tag_inner.is_empty() || tag_inner.starts_with('!') || tag_inner.starts_with('?') {
            continue;
        }
        if tag_inner.starts_with('/') {
            depth = depth.saturating_sub(1);
        } else if !tag_inner.ends_with('/') {
            let tag_name = tag_inner
                .split(|c: char| c.is_whitespace() || c == '/')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            if !is_void_html_tag(&tag_name) {
                depth += 1;
            }
        }
    }
    depth
}

fn is_void_html_tag(tag: &str) -> bool {
    matches!(
        tag,
        "area"
            | "base"
            | "br"
            | "col"
            | "embed"
            | "hr"
            | "img"
            | "input"
            | "link"
            | "meta"
            | "param"
            | "source"
            | "track"
            | "wbr"
    )
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
        assert!(html.contains("<h1 id=\"title\">Title</h1>"));
        assert!(html.contains("<table>"));
        assert!(html.contains("<td>1</td>"));
        assert!(html.contains("<code class=\"language-rust\">"));
    }

    #[test]
    fn deduplicates_heading_ids_like_github() {
        let md = "## Why GitCraft?\n\n## Features\n\n## Features\n";
        let html = render_html(md);
        assert!(html.contains("<h2 id=\"why-gitcraft\">Why GitCraft?</h2>"));
        assert!(html.contains("<h2 id=\"features\">Features</h2>"));
        assert!(html.contains("<h2 id=\"features-1\">Features</h2>"));
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

        assert!(html.contains("<h1 id=\"title\">Title</h1>"));
        assert!(!html.contains("diff-deleted\"><h1"));
        assert!(
            html.contains("<div class=\"diff-block diff-deleted\"><p>Old paragraph.</p>\n</div>")
        );
        assert!(html.contains("<div class=\"diff-block diff-added\"><p>New paragraph.</p>\n</div>"));
        assert!(html.contains("<p>Keep me.</p>"));
    }

    #[test]
    fn diff_html_keeps_open_html_containers_together() {
        let md = "<details><summary>More</summary>\n\nInner paragraph.\n\n</details>\n";
        let html = render_diff_html(None, Some(md));
        assert_eq!(html.matches("diff-added").count(), 1);
        assert!(
            html.contains("<details><summary>More</summary>\n<p>Inner paragraph.</p>\n</details>")
        );
    }

    #[test]
    fn diff_html_handles_new_and_deleted_files() {
        let added = render_diff_html(None, Some("# Fresh\n"));
        assert!(added
            .contains("<div class=\"diff-block diff-added\"><h1 id=\"fresh\">Fresh</h1>\n</div>"));

        let deleted = render_diff_html(Some("# Gone\n"), None);
        assert!(deleted
            .contains("<div class=\"diff-block diff-deleted\"><h1 id=\"gone\">Gone</h1>\n</div>"));
    }
}
