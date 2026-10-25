-- Hold Bot API calls until a spec answers them. Nothing reaches Telegram.
return function(T)
  local fake = { calls = {} }
  T.loadToken = function(done) done("123:test-token") end
  T.http = function(url, method, body, headers, done)
    local name = url:match("/bot[^/]+/(%w+)$") or "file"
    fake.calls[#fake.calls + 1] = { name = name, params = body and hs.json.decode(body) or {},
      url = url, method = method, headers = headers, done = done }
  end
  function fake.named(name)
    local out = {}
    for _, call in ipairs(fake.calls) do if call.name == name then out[#out + 1] = call end end
    return out
  end
  function fake.reply(call, status, result, extra)
    local body = extra or hs.json.encode({ ok = status == 200, result = result,
      description = status == 200 and nil or "try again" })
    call.done(status, body)
  end
  return fake
end
