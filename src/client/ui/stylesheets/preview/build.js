// Builds ../preview.html: a browser reference render of default.scss, for diffing against the
// Roblox render of the same sheet.
//
//   node build.js            one shot
//   node build.js --watch    rebuild when the SCSS or the page parts change
//   node build.js --open     build, then open the result
//   node build.js --verbose  keep dart-sass's deprecation warnings (the sheet raises none today)
//   node build.js --fonts    re-fetch fonts.css from Google Fonts, then build
//
// Run it through ../../../../../build_preview.bat, which finds dart-sass the same way
// build_stylesheets.bat finds outlass.
//
// The pipeline is: dart-sass compiles web.scss -> substitute the two things the browser cannot
// take -> concatenate the page around it -> check the result. Every substitution is reported,
// because each one is a place where the browser and Roblox do not agree and the preview is
// papering over it. Both of the remaining ones are Roblox-only syntax with no CSS meaning; the
// substitutions that existed because outlass and dart-sass disagreed are gone.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const HERE = __dirname;
const SHEETS = path.dirname(HERE);
const OUT = path.join(SHEETS, "preview.html");
const COMPILED = path.join(HERE, ".compiled.css");

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);

// ----- dart-sass -------------------------------------------------------------------------------

// `sass` from PATH if it is installed, otherwise npx, mirroring build_stylesheets.bat.
function sass_command() {
  const probe = spawnSync("sass", ["--version"], { shell: true, encoding: "utf8" });
  if (!probe.error && probe.status === 0) {
    return { cmd: "sass", prefix: [], version: "dart-sass " + probe.stdout.trim().split(" ")[0] };
  }
  return { cmd: "npx", prefix: ["-y", "sass@1"], version: "dart-sass via npx" };
}

function compile() {
  const sass = sass_command();
  const opts = ["--no-source-map", "--load-path=" + SHEETS];
  if (!flag("--verbose")) {
    opts.push("--quiet"); // the sheet is deprecation-clean today; --verbose is there for when it isn't
  }
  const run = spawnSync(
    sass.cmd,
    [...sass.prefix, ...opts, path.join(HERE, "web.scss"), COMPILED],
    { shell: true, encoding: "utf8" }
  );
  const noise = (run.stderr || "").split("\n").filter((l) => !l.startsWith("npm notice")).join("\n").trim();
  const fail = (why) => {
    fs.rmSync(COMPILED, { force: true }); // never leave a half-written sheet behind
    throw new Error("dart-sass failed (" + sass.cmd + "):\n" + why);
  };
  if (run.status !== 0 || !fs.existsSync(COMPILED)) {
    fail(noise || String(run.error || "no output"));
  }
  // A dart-sass error still writes a CSS file, with the error text as a body::before. Catch that,
  // or the page quietly becomes an error message with no styles.
  const css = fs.readFileSync(COMPILED, "utf8");
  if (css.startsWith("/* Error:")) {
    fail(css.slice(0, css.indexOf("*/") + 2));
  }
  if (noise) {
    console.log(noise + "\n");
  }
  return { css, using: sass.version };
}

// ----- substitutions ---------------------------------------------------------------------------

function browserise(css) {
  const notes = [];

  // 1. Roblox class names used as element selectors. <frame> is a void element in the HTML parser
  //    and cannot hold children, so custom-element names stand in for all three.
  let els = 0;
  css = css.replace(/^(Frame|TextButton|TextLabel)(?=[, {])/gm, (_, n) => {
    els++;
    return "rbx-" + n.toLowerCase();
  });
  notes.push("rewrote " + els + " element selectors to rbx-*");

  // 2. `@priority` is an outlass at-rule for StyleRule.Priority; comment it out so the block parses.
  //    The browser reaches the same result by source order anyway.
  let prio = 0;
  css = css.replace(/@priority\s+(\d+);/g, (_, n) => {
    prio++;
    return "/* @priority " + n + "; outlass-only */";
  });
  notes.push("commented out " + prio + " @priority rule(s)");

  return { css: css.replace(/\n{3,}/g, "\n\n").trim() + "\n", notes };
}

// ----- checks ----------------------------------------------------------------------------------

// The page is assembled by concatenation, so nothing validates it on the way through. These are the
// mistakes that concatenation actually makes.
function check(html) {
  const problems = [];
  const note = [];

  const style_open = (html.match(/<style>/g) || []).length;
  const style_close = (html.match(/<\/style>/g) || []).length;
  if (style_open !== 1 || style_close !== 1) {
    problems.push("expected one <style> block, found " + style_open + "/" + style_close);
  }

  const css = html.slice(html.indexOf("<style>") + 7, html.indexOf("</style>"));
  const open = (css.match(/\{/g) || []).length;
  const close = (css.match(/\}/g) || []).length;
  if (open !== close) {
    problems.push("unbalanced CSS braces: " + open + " { vs " + close + " }");
  }

  for (const tag of ["rbx-frame", "rbx-textlabel", "rbx-textbutton", "div", "figure"]) {
    const body = html.slice(html.indexOf("<body>"));
    const o = (body.match(new RegExp("<" + tag + "[ >]", "g")) || []).length;
    const c = (body.match(new RegExp("</" + tag + ">", "g")) || []).length;
    if (o !== c) {
      problems.push(tag + ": " + o + " open vs " + c + " close");
    }
  }

  if ((css.match(/:\s*\$[a-z]/g) || []).length > 0) {
    problems.push("a bare $var survived into the CSS");
  }
  if ((css.match(/^(Frame|TextButton|TextLabel)[, {]/gm) || []).length > 0) {
    problems.push("a Roblox element selector survived into the CSS");
  }

  // Coverage both ways: every class the sheet defines should be rendered somewhere, and every class
  // the markup uses should have a rule -- except the two known gaps, which the page documents.
  const KNOWN_UNSTYLED = ["accent-bar", "metal-fill"];
  const sheet = css.slice(css.indexOf("THE SHEET"));
  const defined = new Set((sheet.match(/\.[a-zA-Z][a-zA-Z0-9-]*/g) || []).map((c) => c.slice(1)));
  defined.delete("scss"); // filenames in comments
  const used = new Set(
    (html.match(/class="([^"]+)"/g) || []).flatMap((m) => m.slice(7, -1).split(/\s+/))
  );

  const unrendered = [...defined].filter((c) => !used.has(c));
  if (unrendered.length) {
    note.push("sheet classes with no sample on the page: " + unrendered.join(" "));
  }
  const unstyled = [...used].filter((c) => !defined.has(c) && !c.startsWith("h-"));
  const surprising = unstyled.filter((c) => !KNOWN_UNSTYLED.includes(c));
  if (surprising.length) {
    note.push("markup classes with no rule: " + surprising.join(" "));
  }
  const gone = KNOWN_UNSTYLED.filter((c) => defined.has(c));
  if (gone.length) {
    note.push("now defined in the sheet, so the page's note about them is stale: " + gone.join(" "));
  }

  return { problems, note };
}

// ----- fonts -----------------------------------------------------------------------------------

// Rewrites fonts.css from the Google Fonts API, aliasing each family to the name the sheet asks
// for. Only needed when a family changes; the checked-in fonts.css is what a normal build uses.
async function refresh_fonts() {
  const alias = { Michroma: "Michroma", "Roboto Mono": "RobotoMono", "Source Sans 3": "Source Sans Pro" };
  const url =
    "https://fonts.googleapis.com/css2?family=Michroma&family=Roboto+Mono:wght@400;700" +
    "&family=Source+Sans+3:ital,wght@0,400;0,700;1,400&display=swap";
  const res = await fetch(url, {
    headers: {
      // without a browser UA the API serves ttf rather than woff2
      "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36",
    },
  });
  if (!res.ok) {
    throw new Error("Google Fonts returned " + res.status);
  }
  const src = await res.text();
  const faces = [];
  const re = /\/\* latin \*\/\s*(@font-face\s*\{[^}]*\})/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    let face = m[1];
    const family = /font-family:\s*'([^']+)'/.exec(face)[1];
    if (!(family in alias)) continue;
    face = face.replace(/font-family:\s*'[^']+'/, "font-family: '" + alias[family] + "'");
    face = face.replace(/src:\s*url\(/, "src: local('" + family + "'), url("); // a local copy wins
    faces.push(face.replace(/\n\s*/g, "\n  ").trim());
  }
  if (faces.length === 0) {
    throw new Error("no latin @font-face blocks matched; the API response shape changed");
  }
  fs.writeFileSync(path.join(HERE, "fonts.css"), faces.join("\n") + "\n");
  console.log("fonts.css: " + faces.length + " faces refreshed");
}

// ----- build -----------------------------------------------------------------------------------

function build() {
  const started = Date.now();
  const { css, using } = compile();
  const { css: sheet, notes } = browserise(css);

  const html = [
    fs.readFileSync(path.join(HERE, "page.head.html"), "utf8"),
    fs.readFileSync(path.join(HERE, "fonts.css"), "utf8"),
    fs.readFileSync(path.join(HERE, "harness.css"), "utf8"),
    sheet,
    fs.readFileSync(path.join(HERE, "page.body.html"), "utf8"),
  ].join("");
  fs.writeFileSync(OUT, html);
  fs.rmSync(COMPILED, { force: true });

  const { problems, note } = check(html);
  console.log("preview.html  " + html.split("\n").length + " lines, " + (html.length / 1024).toFixed(0) + "KB  (" + using + ", " + (Date.now() - started) + "ms)");
  for (const n of notes) console.log("  . " + n);
  for (const n of note) console.log("  ? " + n);
  for (const p of problems) console.log("  ! " + p);
  return problems.length === 0;
}

function open_it() {
  const r = spawnSync("cmd", ["/c", "start", "", OUT.replace(/\//g, "\\")], { stdio: "ignore" });
  if (r.error || r.status !== 0) {
    console.log("  ! could not open it (" + (r.error || "exit " + r.status) + ") -- open " + OUT + " yourself");
  }
}

async function main() {
  if (flag("--fonts")) {
    await refresh_fonts();
  }

  let ok = build();
  if (flag("--open")) {
    open_it();
  }

  if (!flag("--watch")) {
    process.exit(ok ? 0 : 1);
  }

  // Rebuild on any change to the partials or the page parts. fs.watch fires more than once per
  // save on Windows, hence the debounce.
  let timer = null;
  const bump = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      try {
        console.log("\n--- " + new Date().toLocaleTimeString());
        build();
      } catch (e) {
        console.log(String(e.message || e));
      }
    }, 150);
  };
  for (const dir of [path.join(SHEETS, "default"), HERE]) {
    fs.watch(dir, { persistent: true }, (_, file) => {
      if (file && !file.startsWith(".") && file !== "fonts.css") bump();
    });
  }
  console.log("watching " + path.join(SHEETS, "default") + " and " + HERE + " -- ctrl+c to stop");
}

main().catch((e) => {
  console.error(String(e.message || e));
  process.exit(1);
});
