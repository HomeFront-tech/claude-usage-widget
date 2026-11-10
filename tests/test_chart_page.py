"""Chart aggregation and the page-side demo boundary, exercised with Node."""
import shutil
import subprocess
import unittest
from pathlib import Path

PAGE = (Path(__file__).resolve().parent.parent / "chart.html").read_text(encoding="utf-8")
SCRIPT = PAGE.rsplit("<script>", 1)[1].rsplit("</script>", 1)[0]


@unittest.skipUnless(shutil.which("node"), "node isn't installed")
class ChartPage(unittest.TestCase):
    def run_js(self, source):
        result = subprocess.run(["node", "-e", source], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_all_includes_earlier_and_desktop_only_history(self):
        aggregation = SCRIPT[SCRIPT.index("const METRICS ="):SCRIPT.index("function quoteTokens(")]
        self.run_js('''
const assert = require("assert");
const obj = v => v && typeof v === "object" ? v : {};
const RANGES = [{k:"ALL", label:"all time"}, {k:"1D", span:86400, label:"past day"}];
let range = "ALL", metric = "tokens";
const now = Math.floor(Date.now()/3600000)*3600;
const row = (days, tokens) => ({t: now-days*86400, m:{"claude-sonnet-4-5":[tokens,0,0,0,1,0]}, s:[]});
let tokHours = [row(3, 10)], tokDesktop = [row(70, 20), row(40, 30)];
''' + aggregation + '''
let result = buildTokens();
assert.equal(result.totals[0], 60);
assert(result.bk.starts[0] <= now-70*86400);
tokHours = [];
result = buildTokens();
assert.equal(result.totals[0], 50);
assert(result.bk.starts[0] <= now-70*86400);
range = "1D";
assert.equal(buildTokens().hasPrev, true);
tokDesktop = [];
assert.equal(buildTokens().hasPrev, false);
''')

    def test_demo_ignores_live_sample(self):
        handler = next(line for line in SCRIPT.splitlines() if line.startswith("window.onPoint ="))
        self.run_js('''
const assert = require("assert");
const window = {}, INIT = {demo:true}, points = [];
const obj = v => v;
let current = {plan:"demo"}, rendered = 0;
function render() { rendered++; }
''' + handler + '''
window.onPoint({t:123, v:{session:98}, r:{}}, {plan:"real"});
assert.equal(points.length, 0);
assert.equal(current.plan, "demo");
assert.equal(rendered, 0);
INIT.demo = false;
window.onPoint({t:123, v:{session:98}, r:{}}, {plan:"real"});
assert.equal(points.length, 1);
assert.equal(current.plan, "real");
assert.equal(rendered, 1);
''')


if __name__ == "__main__":
    unittest.main()
