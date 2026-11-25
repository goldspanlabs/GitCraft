#!/usr/bin/env bash
# Builds a fictional demo repository for GitCraft screenshots.
#
#   scripts/make-demo-repo.sh [TARGET_DIR]      (default: ~/GitCraftDemo)
#
# TARGET_DIR gets two folders:
#   nimbus/            the repo to open in GitCraft
#   nimbus-hotfix/     a linked worktree of it
#   .remote/nimbus.git a bare repo standing in for the GitHub remote
#
# Every person, email and project name is made up. The remote is configured with a
# github.com URL, but a repo-local `insteadOf` points it at the bare repo, so fetch and
# push work offline and touch nothing real. GitCraft reads the rewritten (local) URL,
# so the remote shows the generic cloud icon rather than GitHub's.
# Run it again with a new TARGET_DIR to get a fresh copy; it never deletes anything.
set -euo pipefail

TARGET="${1:-$HOME/GitCraftDemo}"
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
    echo "error: $TARGET already exists and is not empty. Pick another folder or remove it first." >&2
    exit 1
fi
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
REPO="$TARGET/nimbus"
BARE="$TARGET/.remote/nimbus.git"
FAKE_URL="https://github.com/nimbus-weather/nimbus.git"

# Keep the user's global git config (hooks, signing, templates) out of the way.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

NOW=$(date +%s)
# Commits are spread over the last ~6 weeks so the dates read as recent.
at() { # at DAYS_AGO HOUR:MIN
    local days=$1 hm=$2
    local base=$(( NOW - days * 86400 ))
    local day_start=$(( base - base % 86400 ))
    local h=${hm%:*} m=${hm#*:}
    echo $(( day_start + 10#$h * 3600 + 10#$m * 60 ))
}

# macOS ships bash 3.2, which has no associative arrays.
person() { # person WHO -> "Name|email"
    case $1 in
        maya)  echo "Maya Okafor|maya.okafor@example.com" ;;
        leo)   echo "Leo Brandt|leo.brandt@example.com" ;;
        priya) echo "Priya Raman|priya.raman@example.com" ;;
        sam)   echo "Sam Whitaker|sam.whitaker@example.com" ;;
        ines)  echo "Inês Carvalho|ines.carvalho@example.com" ;;
    esac
}
name_of()  { local p; p=$(person "$1"); echo "${p%%|*}"; }
email_of() { local p; p=$(person "$1"); echo "${p#*|}"; }

commit() { # commit WHO DAYS_AGO HH:MM "message" [body]
    local who=$1 days=$2 hm=$3 msg=$4 body=${5:-}
    local ts; ts="$(at "$days" "$hm") +0000"
    git add -A
    GIT_AUTHOR_NAME="$(name_of "$who")" GIT_AUTHOR_EMAIL="$(email_of "$who")" GIT_AUTHOR_DATE="$ts" \
    GIT_COMMITTER_NAME="$(name_of "$who")" GIT_COMMITTER_EMAIL="$(email_of "$who")" GIT_COMMITTER_DATE="$ts" \
        git commit -q -m "$msg" ${body:+-m "$body"}
}

merge() { # merge WHO DAYS_AGO HH:MM BRANCH "message"
    local who=$1 days=$2 hm=$3 branch=$4 msg=$5
    local ts; ts="$(at "$days" "$hm") +0000"
    GIT_AUTHOR_NAME="$(name_of "$who")" GIT_AUTHOR_EMAIL="$(email_of "$who")" GIT_AUTHOR_DATE="$ts" \
    GIT_COMMITTER_NAME="$(name_of "$who")" GIT_COMMITTER_EMAIL="$(email_of "$who")" GIT_COMMITTER_DATE="$ts" \
        git merge -q --no-ff "$branch" -m "$msg"
}

tag() { # tag WHO DAYS_AGO HH:MM NAME "message"
    local who=$1 days=$2 hm=$3 name=$4 msg=$5
    local ts; ts="$(at "$days" "$hm") +0000"
    GIT_COMMITTER_NAME="$(name_of "$who")" GIT_COMMITTER_EMAIL="$(email_of "$who")" GIT_COMMITTER_DATE="$ts" \
        git tag -a "$name" -m "$msg"
}

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

git init -q -b main "$REPO"
cd "$REPO"
git config user.name "$(name_of maya)"
git config user.email "$(email_of maya)"
git config commit.gpgsign false
git config tag.gpgsign false

# ---------------------------------------------------------------- scaffold
w README.md <<'EOF'
# Nimbus

A tiny, fast weather dashboard for your menu bar and browser.

## Getting started

```sh
npm install
npm run dev
```
EOF
w package.json <<'EOF'
{
  "name": "nimbus",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "test": "vitest run"
  },
  "dependencies": {
    "date-fns": "^3.6.0"
  },
  "devDependencies": {
    "typescript": "^5.5.0",
    "vite": "^5.3.0",
    "vitest": "^2.0.0"
  }
}
EOF
w .gitignore <<'EOF'
node_modules/
dist/
.env
EOF
w src/main.ts <<'EOF'
import { fetchCurrent } from "./api/client";
import { renderCurrent } from "./ui/current";

const root = document.querySelector<HTMLDivElement>("#app")!;

async function boot() {
  const data = await fetchCurrent("Toronto");
  root.replaceChildren(renderCurrent(data));
}

boot();
EOF
commit maya 41 09:12 "Scaffold Nimbus with Vite and TypeScript"

w src/api/client.ts <<'EOF'
export interface Current {
  city: string;
  tempC: number;
  condition: string;
  updatedAt: string;
}

const BASE_URL = "https://api.example.com/v1";

export async function fetchCurrent(city: string): Promise<Current> {
  const res = await fetch(`${BASE_URL}/current?city=${encodeURIComponent(city)}`);
  if (!res.ok) throw new Error(`Weather request failed: ${res.status}`);
  return res.json();
}
EOF
commit maya 40 14:30 "Add weather API client"

w src/ui/current.ts <<'EOF'
import type { Current } from "../api/client";

export function renderCurrent(data: Current): HTMLElement {
  const card = document.createElement("section");
  card.className = "card";
  card.innerHTML = `
    <h2>${data.city}</h2>
    <p class="temp">${data.tempC}°</p>
    <p class="condition">${data.condition}</p>
  `;
  return card;
}
EOF
commit leo 39 11:05 "Render the current conditions card"

w src/styles.css <<'EOF'
:root {
  --bg: #f7f8fb;
  --card: #ffffff;
  --text: #1c2230;
  --accent: #3b82f6;
}

body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Inter", sans-serif;
  background: var(--bg);
  color: var(--text);
}

.card {
  background: var(--card);
  border-radius: 14px;
  padding: 20px 24px;
  box-shadow: 0 1px 3px rgb(0 0 0 / 0.08);
}

.temp {
  font-size: 56px;
  font-weight: 600;
  margin: 4px 0;
}
EOF
commit priya 38 16:40 "Add base styles for the dashboard"

w src/api/client.test.ts <<'EOF'
import { describe, expect, it, vi } from "vitest";
import { fetchCurrent } from "./client";

describe("fetchCurrent", () => {
  it("throws on a failed request", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 503 }));
    await expect(fetchCurrent("Oslo")).rejects.toThrow("503");
  });
});
EOF
commit sam 37 10:20 "Test the API client error path"

sed -i.bak 's/"version": "0.1.0"/"version": "1.0.0"/' package.json && rm package.json.bak
commit maya 36 17:55 "Bump version to 1.0.0"
tag maya 36 18:00 v1.0.0 "Nimbus 1.0"

# ---------------------------------------------------------------- hourly forecast + units fix in parallel
git checkout -q -b feature/hourly-forecast
w src/api/forecast.ts <<'EOF'
import { BASE_URL } from "./config";

export interface HourlyPoint {
  time: string;
  tempC: number;
  precipChance: number;
}

export async function fetchHourly(city: string, hours = 24): Promise<HourlyPoint[]> {
  const url = `${BASE_URL}/forecast/hourly?city=${encodeURIComponent(city)}&hours=${hours}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Forecast request failed: ${res.status}`);
  const body = await res.json();
  return body.points;
}
EOF
w src/api/config.ts <<'EOF'
export const BASE_URL = import.meta.env.VITE_API_URL ?? "https://api.example.com/v1";
EOF
commit leo 35 10:15 "Fetch the hourly forecast"

git checkout -q main
git checkout -q -b fix/units-rounding
w src/units.ts <<'EOF'
export type Unit = "C" | "F";

export function formatTemp(celsius: number, unit: Unit = "C"): string {
  const value = unit === "F" ? celsius * 9 / 5 + 32 : celsius;
  return `${Math.round(value)}°${unit}`;
}
EOF
commit priya 34 13:02 "Round temperatures and support Fahrenheit"

git checkout -q feature/hourly-forecast
w src/ui/hourly.ts <<'EOF'
import { format } from "date-fns";
import type { HourlyPoint } from "../api/forecast";

export function renderHourly(points: HourlyPoint[]): HTMLElement {
  const strip = document.createElement("ol");
  strip.className = "hourly";
  for (const point of points) {
    const item = document.createElement("li");
    item.innerHTML = `
      <span class="hour">${format(new Date(point.time), "ha")}</span>
      <span class="temp">${Math.round(point.tempC)}°</span>
      <span class="rain">${point.precipChance}%</span>
    `;
    strip.append(item);
  }
  return strip;
}
EOF
commit leo 33 15:47 "Add the hourly forecast strip"

git checkout -q fix/units-rounding
w src/units.test.ts <<'EOF'
import { expect, it } from "vitest";
import { formatTemp } from "./units";

it("rounds and converts", () => {
  expect(formatTemp(21.6)).toBe("22°C");
  expect(formatTemp(0, "F")).toBe("32°F");
});
EOF
commit sam 32 09:30 "Cover unit conversion with tests"

git checkout -q main
merge maya 31 11:00 fix/units-rounding "Merge branch 'fix/units-rounding'"

git checkout -q feature/hourly-forecast
cat >> src/styles.css <<'EOF'

.hourly {
  display: flex;
  gap: 12px;
  overflow-x: auto;
  padding: 0;
  list-style: none;
}

.hourly li {
  display: grid;
  justify-items: center;
  min-width: 48px;
}
EOF
commit priya 30 14:12 "Style the hourly strip"

git checkout -q main
merge maya 29 10:40 feature/hourly-forecast "Merge branch 'feature/hourly-forecast'"

w src/main.ts <<'EOF'
import { fetchCurrent } from "./api/client";
import { fetchHourly } from "./api/forecast";
import { renderCurrent } from "./ui/current";
import { renderHourly } from "./ui/hourly";

const root = document.querySelector<HTMLDivElement>("#app")!;

async function boot(city = "Toronto") {
  const [current, hourly] = await Promise.all([fetchCurrent(city), fetchHourly(city)]);
  root.replaceChildren(renderCurrent(current), renderHourly(hourly));
}

boot();
EOF
commit leo 28 16:25 "Show the hourly forecast on the dashboard"

sed -i.bak 's/"version": "1.0.0"/"version": "1.1.0"/' package.json && rm package.json.bak
commit maya 27 12:00 "Release 1.1.0"
tag maya 27 12:05 v1.1.0 "Nimbus 1.1: hourly forecast"

# ---------------------------------------------------------------- push to the "GitHub" remote
mkdir -p "$(dirname "$BARE")"
git init -q --bare -b main "$BARE"
git remote add origin "$FAKE_URL"
git config "url.$BARE.insteadOf" "$FAKE_URL"
git push -q -u origin main --tags

# ---------------------------------------------------------------- location search (merged), dark mode (open), offline cache (local)
git checkout -q -b feature/location-search
w src/api/geocode.ts <<'EOF'
import { BASE_URL } from "./config";

export interface Place {
  id: string;
  name: string;
  country: string;
}

export async function searchPlaces(query: string): Promise<Place[]> {
  if (query.trim().length < 2) return [];
  const res = await fetch(`${BASE_URL}/places?q=${encodeURIComponent(query)}`);
  if (!res.ok) return [];
  return res.json();
}
EOF
commit ines 25 10:05 "Add place search endpoint"

git checkout -q main
git checkout -q -b feature/dark-mode
cat >> src/styles.css <<'EOF'

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1115;
    --card: #181b22;
    --text: #e6e8ee;
  }
}
EOF
commit priya 24 15:30 "Add a dark theme that follows the system"

git checkout -q feature/location-search
w src/ui/search.ts <<'EOF'
import { searchPlaces, type Place } from "../api/geocode";

export function renderSearch(onPick: (place: Place) => void): HTMLElement {
  const input = document.createElement("input");
  input.type = "search";
  input.placeholder = "Search a city…";

  let timer: ReturnType<typeof setTimeout> | undefined;
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const [first] = await searchPlaces(input.value);
      if (first) onPick(first);
    }, 250);
  });
  return input;
}
EOF
commit ines 22 11:48 "Debounce the city search box"

git checkout -q main
merge maya 20 09:15 feature/location-search "Merge branch 'feature/location-search'"
git push -q origin main
git push -q origin feature/location-search

git checkout -q feature/dark-mode
w src/theme.ts <<'EOF'
export type Theme = "system" | "light" | "dark";

const KEY = "nimbus.theme";

export function applyTheme(theme: Theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem(KEY, theme);
}

export function savedTheme(): Theme {
  return (localStorage.getItem(KEY) as Theme | null) ?? "system";
}
EOF
commit priya 19 14:05 "Let people pick light, dark or system"
git push -q -u origin feature/dark-mode

git checkout -q main
git checkout -q -b release/1.2
sed -i.bak 's/"version": "1.1.0"/"version": "1.2.0-rc.1"/' package.json && rm package.json.bak
commit maya 17 10:30 "Prepare 1.2.0-rc.1"
tag maya 17 10:35 v1.2.0-rc.1 "Nimbus 1.2 release candidate"
git push -q -u origin release/1.2 --tags

git checkout -q main
git checkout -q -b feature/offline-cache
w src/cache.ts <<'EOF'
const TTL_MS = 10 * 60 * 1000;

interface Entry<T> {
  value: T;
  storedAt: number;
}

export function cached<T>(key: string, load: () => Promise<T>): Promise<T> {
  const raw = localStorage.getItem(key);
  if (raw) {
    const entry: Entry<T> = JSON.parse(raw);
    if (Date.now() - entry.storedAt < TTL_MS) return Promise.resolve(entry.value);
  }
  return load().then((value) => {
    localStorage.setItem(key, JSON.stringify({ value, storedAt: Date.now() }));
    return value;
  });
}
EOF
commit sam 15 16:20 "Cache API responses for ten minutes"

git checkout -q main
w src/ui/current.ts <<'EOF'
import type { Current } from "../api/client";
import { formatTemp, type Unit } from "../units";

export function renderCurrent(data: Current, unit: Unit = "C"): HTMLElement {
  const card = document.createElement("section");
  card.className = "card";
  card.innerHTML = `
    <h2>${data.city}</h2>
    <p class="temp">${formatTemp(data.tempC, unit)}</p>
    <p class="condition">${data.condition}</p>
    <p class="updated">Updated ${new Date(data.updatedAt).toLocaleTimeString()}</p>
  `;
  return card;
}
EOF
commit leo 13 11:10 "Show units and last-updated time on the card"

git checkout -q feature/offline-cache
w src/api/client.ts <<'EOF'
import { cached } from "../cache";
import { BASE_URL } from "./config";

export interface Current {
  city: string;
  tempC: number;
  condition: string;
  updatedAt: string;
}

export function fetchCurrent(city: string): Promise<Current> {
  return cached(`current:${city}`, async () => {
    const res = await fetch(`${BASE_URL}/current?city=${encodeURIComponent(city)}`);
    if (!res.ok) throw new Error(`Weather request failed: ${res.status}`);
    return res.json();
  });
}
EOF
commit sam 11 15:00 "Serve current conditions from the cache when fresh"

git checkout -q feature/dark-mode
w src/ui/theme-toggle.ts <<'EOF'
import { applyTheme, savedTheme, type Theme } from "../theme";

const ORDER: Theme[] = ["system", "light", "dark"];
const LABELS: Record<Theme, string> = { system: "Auto", light: "Light", dark: "Dark" };

export function renderThemeToggle(): HTMLButtonElement {
  const button = document.createElement("button");
  let current = savedTheme();
  button.textContent = LABELS[current];
  button.addEventListener("click", () => {
    current = ORDER[(ORDER.indexOf(current) + 1) % ORDER.length];
    applyTheme(current);
    button.textContent = LABELS[current];
  });
  return button;
}
EOF
commit priya 9 13:40 "Add a theme toggle to the header"

git checkout -q main
w src/api/client.test.ts <<'EOF'
import { describe, expect, it, vi } from "vitest";
import { fetchCurrent } from "./client";

describe("fetchCurrent", () => {
  it("throws on a failed request", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 503 }));
    await expect(fetchCurrent("Oslo")).rejects.toThrow("503");
  });

  it("encodes the city name", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: () => ({}) });
    vi.stubGlobal("fetch", fetchMock);
    await fetchCurrent("São Paulo");
    expect(fetchMock.mock.calls[0][0]).toContain("S%C3%A3o%20Paulo");
  });
});
EOF
commit ines 7 10:05 "Test that city names are URL-encoded"
git push -q origin main

# A teammate pushes to main from elsewhere, so local main shows "1 behind" after fetch.
OTHER="$TARGET/.remote/teammate"
git clone -q "$BARE" "$OTHER"
(
    cd "$OTHER"
    git config commit.gpgsign false
    cat >> README.md <<'EOF'

## Configuration

Set `VITE_API_URL` to point Nimbus at your own weather API.
EOF
    commit maya 5 09:50 "Document the API URL setting"
    git push -q origin main
)
rm -rf "$OTHER"
git fetch -q origin

# ---------------------------------------------------------------- worktree for a hotfix
git worktree add -q -b hotfix/search-crash "$TARGET/nimbus-hotfix" v1.1.0
(
    cd "$TARGET/nimbus-hotfix"
    w src/api/client.ts <<'EOF'
export interface Current {
  city: string;
  tempC: number;
  condition: string;
  updatedAt: string;
}

const BASE_URL = "https://api.example.com/v1";

export async function fetchCurrent(city: string): Promise<Current> {
  const name = city.trim();
  if (!name) throw new Error("City name is empty");
  const res = await fetch(`${BASE_URL}/current?city=${encodeURIComponent(name)}`);
  if (!res.ok) throw new Error(`Weather request failed: ${res.status}`);
  return res.json();
}
EOF
    commit leo 3 17:20 "Guard against an empty city name"
)

# ---------------------------------------------------------------- current branch with work in progress
git checkout -q feature/dark-mode

# Two stashes.
cat >> src/styles.css <<'EOF'

.card { transition: background 200ms ease; }
EOF
git stash push -q -m "Try a fade between themes"
w src/ui/header.ts <<'EOF'
export function renderHeader(): HTMLElement {
  const header = document.createElement("header");
  header.innerHTML = `<h1>Nimbus</h1>`;
  return header;
}
EOF
git stash push -q -u -m "Header layout experiment"

# Staged: theme now remembers the system preference.
w src/theme.ts <<'EOF'
export type Theme = "system" | "light" | "dark";

const KEY = "nimbus.theme";
const media = window.matchMedia("(prefers-color-scheme: dark)");

export function applyTheme(theme: Theme) {
  const resolved = theme === "system" ? (media.matches ? "dark" : "light") : theme;
  document.documentElement.dataset.theme = resolved;
  localStorage.setItem(KEY, theme);
}

export function savedTheme(): Theme {
  return (localStorage.getItem(KEY) as Theme | null) ?? "system";
}

export function watchSystemTheme() {
  media.addEventListener("change", () => {
    if (savedTheme() === "system") applyTheme("system");
  });
}
EOF
git add src/theme.ts

# Unstaged: palette tweaks and wiring the toggle into main.ts.
cat > src/styles.css.new <<'EOF'
:root {
  --bg: #f7f8fb;
  --card: #ffffff;
  --text: #1c2230;
  --muted: #6b7280;
  --accent: #3b82f6;
}

:root[data-theme="dark"] {
  --bg: #0f1115;
  --card: #181b22;
  --text: #e6e8ee;
  --muted: #9aa3b2;
  --accent: #60a5fa;
}
EOF
sed -n '/^body {/,$p' src/styles.css | sed '/@media (prefers-color-scheme: dark)/,$d' >> src/styles.css.new
mv src/styles.css.new src/styles.css
w src/main.ts <<'EOF'
import { fetchCurrent } from "./api/client";
import { fetchHourly } from "./api/forecast";
import { applyTheme, savedTheme, watchSystemTheme } from "./theme";
import { renderCurrent } from "./ui/current";
import { renderHourly } from "./ui/hourly";
import { renderThemeToggle } from "./ui/theme-toggle";

const root = document.querySelector<HTMLDivElement>("#app")!;

applyTheme(savedTheme());
watchSystemTheme();

async function boot(city = "Toronto") {
  const [current, hourly] = await Promise.all([fetchCurrent(city), fetchHourly(city)]);
  root.replaceChildren(renderThemeToggle(), renderCurrent(current), renderHourly(hourly));
}

boot();
EOF

# Untracked: a new icon set.
w src/icons/moon.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
EOF
w src/icons/sun.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="5"/></svg>
EOF

echo "Demo repo ready: $REPO"
echo "Worktree:        $TARGET/nimbus-hotfix"
