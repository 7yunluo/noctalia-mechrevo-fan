-- Deterministic Noctalia host: exercise the real service without hardware.
local function encode(v)
  if type(v) ~= 'table' then return tostring(v) end
  local keys, out = {}, {}
  for k in pairs(v) do keys[#keys+1] = k end
  table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)
  for _, k in ipairs(keys) do out[#out+1] = tostring(k)..'='..encode(v[k]) end
  return '{'..table.concat(out, ',')..'}'
end
local function host()
  local h = {time=100000, states={}, config={curve='balanced'}, queue={}, ops={}, notices={}}
  local env = setmetatable({}, {__index=_G})
  env.noctalia = {
    nowMs=function() return h.time end,
    getConfig=function(k) return h.config[k] end,
    expandPath=function(p) return p end,
    pluginDataDir=function() return '/mock' end,
    readFile=function() error('missing') end,
    writeFile=function() end,
    log=function() end,
    notify=function(...) h.notices[#h.notices+1]={...} end,
    tr=function(s) return s end,
    setUpdateInterval=function() end,
    json={encode=encode, decode=function(v) assert(type(v)=='table'); return v end},
    state={get=function(k) return h.states[k] end, set=function(k,v) h.states[k]=v end,
      watch=function(_, fn) h.command=fn end},
    runAsync=function(argv, callback)
      h.ops[#h.ops+1]=argv
      if callback then
        assert(#h.queue == 0, 'overlapping operations')
        h.queue[1]={argv=argv,callback=callback}
      end
      return true
    end,
  }
  assert(loadfile('mechrevo-fan/service.luau','t',env))()
  function h:tick(ms) self.time=self.time+(ms or 250);env.update() end
  function h:reply(data, rc)
    local op=assert(table.remove(self.queue,1),'no pending operation')
    op.callback({exitCode=rc or 0,stdout=data})
    return op.argv
  end
  function h:status(t,f0,f1)
    return {ok=true,scale=200,temp0=t or 55,temp1=0,fan0=f0 or 70,fan1=f1 or 60,mode=0,minSpeed=25}
  end
  function h:snap() return self.states['mechrevo_fan.status'] end
  function h:boot(t)
    assert(self:reply()[2]=='auto');self:tick();self:reply(self:status(t))
  end
  h.env=env
  return h
end
local count=0
local function test(name, fn) fn();count=count+1;print('PASS '..name) end

test('same target is reapplied periodically and after auto',function()
  local h=host();h:boot()
  h.command({action='set_raw',raw=120})
  assert(h.queue[1].argv[2]=='set-both' and h.queue[1].argv[3]=='120')
  h:reply(h:status(55,120,120));assert(h:snap().live)
  h:tick(999);assert(#h.queue==0);h:tick(1);h:reply(h:status(55,120,120))
  h.command({action='set_mode',mode='auto'});assert(not h:snap().live);h:reply()
  h.command({action='set_raw',raw=120});assert(h.queue[1].argv[2]=='set-both')
end)
test('commands coalesce and auto waits for the pending pair',function()
  local h=host();h:boot();h.command({action='set_raw',raw=100})
  h.command({action='set_raw',raw=150});h.command({action='set_mode',mode='auto'})
  h:reply(h:status(55,100,100));assert(not h:snap().live)
  h:tick();assert(h:reply()[2]=='auto')
end)
test('curve interpolates and updates when settings change',function()
  local h=host();h:boot(60);h.command({action='set_mode',mode='curve'})
  assert(h.queue[1].argv[3]=='80');h:reply(h:status(70,80,80))
  h:tick(1000);assert(h.queue[1].argv[3]=='110');h:reply(h:status(70,110,110))
  h.config.curve='performance';h.env.onConfigChanged();assert(h.queue[1].argv[3]=='130')
end)
test('both fans must follow; three mismatches request auto',function()
  local h=host();h:boot();h.command({action='set_raw',raw=160})
  for i=1,3 do
    h:reply(h:status(55,160,60));assert(not h:snap().live)
    h:tick(1000)
  end
  assert(h:snap().modeName=='auto' and h.queue[1].argv[2]=='auto')
end)
test('invalid and overheated sensors hand back in manual too',function()
  for _, temp in ipairs({0,96}) do
    local h=host();h:boot();h.command({action='set_raw',raw=100})
    h:reply(h:status(temp,100,100));h:tick()
    assert(h:snap().modeName=='auto' and h.queue[1].argv[2]=='auto')
  end
end)
test('stale readings do not continue manual writes',function()
  local h=host();h:boot();h.command({action='set_raw',raw=100});h:reply(h:status(55,100,100))
  h:tick(15000);assert(h:snap().modeName=='auto' and h.queue[1].argv[2]=='auto')
end)
test('write failure requests auto and keeps its error visible',function()
  local h=host();h:boot();h.command({action='set_raw',raw=100});h:reply(nil,1);h:tick()
  assert(h:reply()[2]=='auto');assert(h:snap().error=='error.write-failed')
end)
test('watchdog never starts another operation over a hung helper',function()
  local h=host();h:boot();h.command({action='set_raw',raw=100});h:tick(11000)
  assert(#h.queue==1 and h:snap().error=='error.helper-stuck')
  local op=table.remove(h.queue,1);op.callback({timedOut=true,exitCode=-1})
  h:tick();assert(h.queue[1].argv[2]=='auto')
end)
test('zero targets retain the user value',function()
  local h=host();h:boot();h.command({action='set_raw',raw=0});assert(h.queue[1].argv[3]=='0')
  h:reply(h:status(55,15,20));assert(h:snap().targetRaw==0 and h:snap().live)
end)
test('invalid commands and unavailable temperatures cannot take control',function()
  local h=host();h:boot(0);h.command({action='set_raw',raw=100});assert(#h.queue==0)
  h.command({action='set_mode',mode='invalid'});assert(h:snap().modeName=='auto')
end)
print(count..' service tests passed')
