use std::collections::{HashMap, HashSet};

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
            wrap_all(&blocks, "diff-added", false)
        }
        (Some(old_md), None) => {
            let blocks = render_blocks(old_md);
            wrap_all(&blocks, "diff-deleted", true)
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
    // GitHub does not support `{#id}` heading attributes, so they are deliberately not enabled.
    Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS
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
    let mut used_ids: HashSet<String> = HashSet::new();
    let mut next_suffix: HashMap<String, usize> = HashMap::new();
    let mut heading_buf: Option<PendingHeading<'a>> = None;

    for event in parser {
        if let Some(mut pending) = heading_buf.take() {
            match event {
                Event::End(TagEnd::Heading(end_level)) => {
                    let resolved_id = match pending.id {
                        Some(explicit) => {
                            used_ids.insert(explicit.to_string());
                            Some(explicit)
                        }
                        None => {
                            let text = collect_plain_text(&pending.inner);
                            let base = github_slug(&text);
                            if used_ids.insert(base.clone()) {
                                // GitHub gives an empty slug no usable id the first time,
                                // then `-1`, `-2`, ...
                                (!base.is_empty()).then(|| CowStr::Boxed(base.into_boxed_str()))
                            } else {
                                let suffix = next_suffix.entry(base.clone()).or_insert(1);
                                let candidate = loop {
                                    let c = format!("{base}-{}", *suffix);
                                    *suffix += 1;
                                    if used_ids.insert(c.clone()) {
                                        break c;
                                    }
                                };
                                Some(CowStr::Boxed(candidate.into_boxed_str()))
                            }
                        }
                    };
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
                // Only block-level HTML can start a container that spans several Markdown
                // blocks (e.g. `<details>`), but inline HTML may still close an open one.
                if matches!(event, Event::Html(_)) || html_depth > 0 {
                    html_depth = update_html_depth(html_depth, raw);
                }
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
        if let Some(closing) = tag_inner.strip_prefix('/') {
            let name = closing.trim().to_ascii_lowercase();
            if is_container_html_tag(&name) {
                depth = depth.saturating_sub(1);
            }
        } else if !tag_inner.ends_with('/') {
            let tag_name = tag_inner
                .split(|c: char| c.is_whitespace() || c == '/')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            if is_container_html_tag(&tag_name) {
                depth += 1;
            }
        }
    }
    depth
}

/// Block containers whose content may be separated by blank lines and so span several
/// Markdown blocks. Void, inline and optional-end-tag elements (`<p>`, `<li>`, `<td>`, `<b>`, ...)
/// are deliberately excluded: an unclosed one must not swallow the rest of the document.
fn is_container_html_tag(tag: &str) -> bool {
    matches!(
        tag,
        "details"
            | "div"
            | "table"
            | "blockquote"
            | "ul"
            | "ol"
            | "dl"
            | "section"
            | "article"
            | "aside"
            | "nav"
            | "header"
            | "footer"
            | "figure"
            | "center"
            | "pre"
            | "main"
            | "address"
            | "form"
            | "fieldset"
    )
}

fn events_to_html(events: Vec<Event<'_>>) -> String {
    let mut out = String::new();
    html::push_html(&mut out, events.into_iter());
    out
}

fn wrap_all(blocks: &[String], class_name: &str, is_deleted: bool) -> String {
    let mut out = String::new();
    for block in blocks {
        push_diff_block(&mut out, class_name, block, is_deleted);
    }
    out
}

fn push_diff_block(out: &mut String, class_name: &str, block: &str, is_deleted: bool) {
    out.push_str("<div class=\"diff-block ");
    out.push_str(class_name);
    out.push_str("\">");
    if is_deleted {
        out.push_str(&tag_deleted_assets(block));
    } else {
        out.push_str(block);
    }
    out.push_str("</div>\n");
}

/// Id prefix for headings in deleted blocks. Generated slugs never contain `:`, so these ids
/// cannot collide with the current document's and anchors keep targeting the current copy.
const DELETED_ID_PREFIX: &str = "old:";

/// Appends `diff-side=old` to relative `src` and `srcset` attributes inside deleted diff blocks
/// and prefixes heading `id`s, regardless of quoting (`"..."`, `'...'`, unquoted), spacing around `=`, or attribute casing.
fn tag_deleted_assets(html: &str) -> String {
    let bytes = html.as_bytes();
    let len = bytes.len();
    let mut out = String::with_capacity(len);
    let mut i = 0;

    while i < len {
        if bytes[i] != b'<' {
            let start = i;
            while i < len && bytes[i] != b'<' {
                i += 1;
            }
            out.push_str(&html[start..i]);
            continue;
        }

        // Preserve HTML comments verbatim.
        if html[i..].starts_with("<!--") {
            let end = html[i + 4..]
                .find("-->")
                .map(|off| i + 4 + off + 3)
                .unwrap_or(len);
            out.push_str(&html[i..end]);
            i = end;
            continue;
        }

        // Only inspect opening tags (`<tag ...>`), skipping closing/declaration tags.
        let tag_start = i;
        i += 1;
        if i >= len || !bytes[i].is_ascii_alphabetic() {
            out.push('<');
            continue;
        }

        // Copy `<tagName`.
        while i < len && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'-' || bytes[i] == b':')
        {
            i += 1;
        }
        out.push_str(&html[tag_start..i]);
        let is_heading = matches!(
            html[tag_start + 1..i].to_ascii_lowercase().as_str(),
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
        );

        // Scan attributes until the closing `>` of this opening tag.
        while i < len {
            let ws_start = i;
            while i < len && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            out.push_str(&html[ws_start..i]);
            if i >= len {
                break;
            }
            if bytes[i] == b'>' {
                out.push('>');
                i += 1;
                break;
            }
            if bytes[i] == b'/' {
                out.push('/');
                i += 1;
                continue;
            }

            // Read attribute name.
            let name_start = i;
            while i < len
                && !bytes[i].is_ascii_whitespace()
                && bytes[i] != b'='
                && bytes[i] != b'>'
                && bytes[i] != b'/'
            {
                i += 1;
            }
            let attr_name = &html[name_start..i];
            out.push_str(attr_name);

            // Optional whitespace before `=`.
            let pre_eq = i;
            while i < len && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i >= len || bytes[i] != b'=' {
                out.push_str(&html[pre_eq..i]);
                continue;
            }
            i += 1; // consume '='
            while i < len && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            out.push_str(&html[pre_eq..i]);
            if i >= len {
                break;
            }

            let is_src = attr_name.eq_ignore_ascii_case("src");
            let is_srcset = attr_name.eq_ignore_ascii_case("srcset");

            // Read attribute value (double-quoted, single-quoted, or unquoted).
            let (val, quote_char) = if bytes[i] == b'"' || bytes[i] == b'\'' {
                let q = bytes[i];
                i += 1;
                let val_start = i;
                while i < len && bytes[i] != q {
                    i += 1;
                }
                let val = &html[val_start..i];
                let closed = i < len && bytes[i] == q;
                if closed {
                    i += 1;
                }
                (val, Some((q as char, closed)))
            } else {
                let val_start = i;
                while i < len && !bytes[i].is_ascii_whitespace() && bytes[i] != b'>' {
                    i += 1;
                }
                (&html[val_start..i], None)
            };

            let rewritten = if is_heading && attr_name.eq_ignore_ascii_case("id") {
                format!("{DELETED_ID_PREFIX}{val}")
            } else if is_srcset {
                rewrite_srcset(val)
            } else if is_src {
                append_old_side_param(val)
            } else {
                val.to_owned()
            };

            if let Some((q, closed)) = quote_char {
                out.push(q);
                out.push_str(&rewritten);
                if closed {
                    out.push(q);
                }
            } else {
                out.push_str(&rewritten);
            }
        }
    }

    out
}

fn rewrite_srcset(val: &str) -> String {
    val.split(',')
        .map(|entry| {
            let trimmed = entry.trim();
            let mut parts = trimmed.splitn(2, char::is_whitespace);
            let url_part = parts.next().unwrap_or("");
            let desc = parts.next();
            let tagged_url = append_old_side_param(url_part);
            match desc {
                Some(d) => format!("{tagged_url} {d}"),
                None => tagged_url,
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn append_old_side_param(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.is_empty()
        || trimmed.starts_with("http://")
        || trimmed.starts_with("https://")
        || trimmed.starts_with("data:")
        || trimmed.starts_with('#')
    {
        return trimmed.to_owned();
    }
    let (base, frag) = match trimmed.find('#') {
        Some(idx) => (&trimmed[..idx], Some(&trimmed[idx..])),
        None => (trimmed, None),
    };
    let sep = if base.contains('?') { '&' } else { '?' };
    match frag {
        Some(f) => format!("{base}{sep}diff-side=old{f}"),
        None => format!("{base}{sep}diff-side=old"),
    }
}

const MAX_LCS_BLOCKS: usize = 1500;

const LARGE_DIFF_NOTICE: &str = "<div class=\"diff-notice\">This change is too large to align block by block, so the changed region is shown as removed and re-added.</div>\n";

fn diff_blocks_html(old: &[String], new: &[String]) -> String {
    // Unchanged leading and trailing blocks need no alignment, which keeps the quadratic
    // step below limited to the region that actually changed.
    let prefix = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    let max_suffix = old.len().min(new.len()) - prefix;
    let suffix = old
        .iter()
        .rev()
        .zip(new.iter().rev())
        .take(max_suffix)
        .take_while(|(a, b)| a == b)
        .count();

    let old_mid = &old[prefix..old.len() - suffix];
    let new_mid = &new[prefix..new.len() - suffix];

    let mut out = String::new();
    for block in &new[..prefix] {
        out.push_str(block);
    }
    if old_mid.len() > MAX_LCS_BLOCKS || new_mid.len() > MAX_LCS_BLOCKS {
        out.push_str(LARGE_DIFF_NOTICE);
        out.push_str(&wrap_all(old_mid, "diff-deleted", true));
        out.push_str(&wrap_all(new_mid, "diff-added", false));
    } else {
        lcs_diff_blocks(old_mid, new_mid, &mut out);
    }
    for block in &new[new.len() - suffix..] {
        out.push_str(block);
    }
    out
}

fn lcs_diff_blocks(old: &[String], new: &[String], out: &mut String) {
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

    let mut i = 0;
    let mut j = 0;
    while i < n && j < m {
        if old[i] == new[j] {
            out.push_str(&new[j]);
            i += 1;
            j += 1;
        } else if dp[(i + 1) * stride + j] >= dp[i * stride + (j + 1)] {
            push_diff_block(out, "diff-deleted", &old[i], true);
            i += 1;
        } else {
            push_diff_block(out, "diff-added", &new[j], false);
            j += 1;
        }
    }
    while i < n {
        push_diff_block(out, "diff-deleted", &old[i], true);
        i += 1;
    }
    while j < m {
        push_diff_block(out, "diff-added", &new[j], false);
        j += 1;
    }
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
        let md = "## Why GitCraft?\n\n## Features\n\n## Features-1\n\n## Features\n";
        let html = render_html(md);
        assert!(html.contains("<h2 id=\"why-gitcraft\">Why GitCraft?</h2>"));
        assert!(html.contains("<h2 id=\"features\">Features</h2>"));
        assert!(html.contains("<h2 id=\"features-1\">Features-1</h2>"));
        assert!(html.contains("<h2 id=\"features-2\">Features</h2>"));
    }

    #[test]
    fn deleted_blocks_tag_relative_assets_with_old_diff_side() {
        let old = concat!(
            "![Logo](assets/logo.png)\n\n",
            "<img src='assets/single.png' data-src=\"keep.png\">\n",
            "<img SRC = \"assets/spaced.png\">\n",
            "<img src=assets/unquoted.png>\n",
            "<source SRCSET = 'assets/a.png 1x, assets/b.png 2x'>\n",
            "<img src=\"https://example.com/badge.svg\">\n",
        );
        let html = render_diff_html(Some(old), None);
        assert!(html.contains("src=\"assets/logo.png?diff-side=old\""));
        assert!(html.contains("src='assets/single.png?diff-side=old'"));
        assert!(html.contains("data-src=\"keep.png\""));
        assert!(html.contains("SRC = \"assets/spaced.png?diff-side=old\""));
        assert!(html.contains("src=assets/unquoted.png?diff-side=old"));
        assert!(html
            .contains("SRCSET = 'assets/a.png?diff-side=old 1x, assets/b.png?diff-side=old 2x'"));
        assert!(html.contains("src=\"https://example.com/badge.svg\""));
    }

    #[test]
    fn repeated_headings_deduplicate_without_quadratic_slowdown() {
        let md = "# Same\n\n".repeat(2_000);
        let html = render_html(&md);
        assert!(html.contains("<h1 id=\"same\">Same</h1>"));
        assert!(html.contains("<h1 id=\"same-1\">Same</h1>"));
        assert!(html.contains("<h1 id=\"same-1999\">Same</h1>"));
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
    fn unclosed_inline_or_optional_tags_do_not_merge_later_blocks() {
        let md = "<p align=center>\n\nOne <b>bold\n\nTwo\n\nThree\n";
        let html = render_diff_html(None, Some(md));
        assert!(html.matches("diff-added").count() >= 3);
    }

    #[test]
    fn heading_braces_are_kept_and_empty_slugs_dedupe() {
        let html = render_html("## Config {#id}\n\n## !!!\n\n## ???\n");
        assert!(html.contains("<h2 id=\"config-id\">Config {#id}</h2>"));
        assert!(html.contains("<h2>!!!</h2>"));
        assert!(html.contains("<h2 id=\"-1\">???</h2>"));
    }

    #[test]
    fn deleted_blocks_prefix_heading_ids() {
        let html = render_diff_html(Some("# Gone\n"), None);
        assert!(html.contains("<h1 id=\"old:gone\">"));
    }

    #[test]
    fn large_docs_with_a_small_change_still_diff_per_block() {
        let para = |i: usize| format!("Paragraph {i}.\n\n");
        let old: String = (0..3000).map(para).collect();
        let new = old.replace("Paragraph 1500.", "Changed 1500.");
        let html = render_diff_html(Some(&old), Some(&new));
        assert!(!html.contains("diff-notice"));
        assert_eq!(html.matches("diff-deleted").count(), 1);
        assert_eq!(html.matches("diff-added").count(), 1);
    }

    #[test]
    fn huge_rewrites_show_a_notice_instead_of_silently_degrading() {
        let old: String = (0..2000).map(|i| format!("Old {i}.\n\n")).collect();
        let new: String = (0..2000).map(|i| format!("New {i}.\n\n")).collect();
        let html = render_diff_html(Some(&old), Some(&new));
        assert!(html.contains("diff-notice"));
        assert_eq!(html.matches("diff-deleted").count(), 2000);
    }

    #[test]
    fn deleted_heading_ids_cannot_collide_with_current_slugs() {
        let html = render_diff_html(Some("# Title\n"), Some("# Old Title\n"));
        assert!(html.contains("<h1 id=\"old:title\">Title</h1>"));
        assert!(html.contains("<h1 id=\"old-title\">Old Title</h1>"));
    }

    #[test]
    fn deleted_raw_html_heading_ids_are_prefixed() {
        let old = "<h2 class=\"t\" id='section'>A</h2>\n\n<H3 ID=other>B</H3>\n";
        let html = render_diff_html(Some(old), None);
        assert!(html.contains("id='old:section'"), "{html}");
        assert!(html.contains("ID=old:other"), "{html}");
    }

    #[test]
    fn inline_html_can_close_an_open_container() {
        let md = "<div>\n\ntext </div>\n\n# Later\n";
        let html = render_diff_html(None, Some(md));
        assert_eq!(html.matches("diff-added").count(), 2, "{html}");
    }

    #[test]
    fn main_and_form_containers_stay_together() {
        let md = "<main>\n\nInner paragraph.\n\n</main>\n";
        let html = render_diff_html(None, Some(md));
        assert_eq!(html.matches("diff-added").count(), 1, "{html}");
    }

    #[test]
    fn diff_html_handles_new_and_deleted_files() {
        let added = render_diff_html(None, Some("# Fresh\n"));
        assert!(added
            .contains("<div class=\"diff-block diff-added\"><h1 id=\"fresh\">Fresh</h1>\n</div>"));

        let deleted = render_diff_html(Some("# Gone\n"), None);
        assert!(deleted.contains(
            "<div class=\"diff-block diff-deleted\"><h1 id=\"old:gone\">Gone</h1>\n</div>"
        ));
    }
}
