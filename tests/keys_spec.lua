-- keys.lua: API keys for the other AIs in the Keychain, through a fake security tool that
-- writes down its arguments (a key must never be one of them).
return function(t, dir)
  local K = dofile(dir .. "/keys.lua")
  t.ok(K.valid("sk-or-v1-testkey123"), "a key-shaped key")
  t.ok(not K.valid("has space1"), "a space inside")
  t.ok(not K.valid("short"), "too short")
  t.ok(not K.valid(("a"):rep(600)), "too long")
  t.ok(not K.valid("sk'quote1234"), "a quote")
  t.ok(not K.valid(nil), "nothing")
  t.eq(K.clean("  sk-or-v1-testkey123\n"), "sk-or-v1-testkey123", "pasted whitespace trimmed")
  t.eq(K.service("openrouter"), "claude-buddy-openrouter", "one Keychain item per AI")

  local tmp = t.tmpdir()
  local sec = tmp .. "/security"
  local f = assert(io.open(sec, "w"))
  f:write([[#!/bin/sh
D=$(dirname "$0")
echo "$@" >> "$D/args"
svc() { while [ $# -gt 0 ]; do [ "$1" = "-s" ] && { echo "$2"; return; }; shift; done; }
case "$1" in
  -i) read -r line; s=$(svc $line); printf '%s' "${line##* -w }" > "$D/item-$s" ;;
  find-generic-password) s=$(svc "$@"); [ -f "$D/item-$s" ] || exit 44
    case " $* " in *" -w "*) cat "$D/item-$s" ;; esac ;;
  delete-generic-password) s=$(svc "$@"); [ -f "$D/item-$s" ] || exit 44; rm -f "$D/item-$s" ;;
esac
]])
  f:close()
  hs.execute("/bin/chmod +x '" .. sec .. "'")
  K.security = sec

  local r = {}
  K.save("openrouter", "bad key", function(ok) r.bad = ok end)
  K.save("openrouter", "sk-or-v1-testkey123", function(ok)
    r.saved = ok
    K.has("openrouter", function(has)
      r.has = has
      K.has("xai", function(other)
        r.other = other
        K.forget("openrouter", function(gone)
          r.gone = gone
          K.forget("xai", function(missing)
            r.missing = missing
            K.has("openrouter", function(after) r.after, r.done = after, true end)
          end)
        end)
      end)
    end)
  end)
  local failing = dofile(dir .. "/keys.lua")
  failing.security = "/usr/bin/false"
  failing.forget("openrouter", function(ok) r.failing = ok end)
  return function()
    if not r.done or r.failing == nil then return false end
    t.eq(r.failing, false, "a security failure is reported")
    t.eq(r.bad, false, "a malformed key isn't saved")
    t.eq(r.saved, true, "saved and read back")
    t.eq(r.has, true, "it's there")
    t.eq(r.other, false, "another AI's isn't")
    t.eq(r.after, false, "forgotten")
    t.eq(r.gone, true, "forget says it worked")
    t.eq(r.missing, true, "forgetting a key that isn't there is fine")
    local args = io.open(tmp .. "/args"):read("a")
    t.ok(args:find("-s claude-buddy-openrouter", 1, true), "its own Keychain item")
    t.ok(not args:find("testkey123", 1, true), "the key is never in security's arguments")
    return true
  end
end
