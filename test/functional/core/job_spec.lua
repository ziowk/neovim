local helpers = require('test.functional.helpers')(after_each)
local clear, eq, eval, execute, feed, insert, neq, next_msg, nvim,
  nvim_dir, ok, source, write_file, mkdir, rmdir = helpers.clear,
  helpers.eq, helpers.eval, helpers.execute, helpers.feed,
  helpers.insert, helpers.neq, helpers.next_message, helpers.nvim,
  helpers.nvim_dir, helpers.ok, helpers.source,
  helpers.write_file, helpers.mkdir, helpers.rmdir
local command = helpers.command
local wait = helpers.wait
local iswin = helpers.iswin
local Screen = require('test.functional.ui.screen')

describe('jobs', function()
  local channel

  before_each(function()
    clear()
    if iswin() then
      helpers.set_shell_powershell()
    end
    channel = nvim('get_api_info')[1]
    nvim('set_var', 'channel', channel)
    source([[
    function! Normalize(data) abort
      " Windows: remove ^M
      return type([]) == type(a:data)
        \ ? map(a:data, 'substitute(v:val, "\r", "", "g")')
        \ : a:data
    endfunction
    function! s:OnEvent(id, data, event) dict
      let userdata = get(self, 'user')
      let data     = Normalize(a:data)
      call rpcnotify(g:channel, a:event, userdata, data)
    endfunction
    let g:job_opts = {
    \ 'on_stdout': function('s:OnEvent'),
    \ 'on_stderr': function('s:OnEvent'),
    \ 'on_exit': function('s:OnEvent'),
    \ 'user': 0
    \ }
    ]])
  end)

  it('uses &shell and &shellcmdflag if passed a string', function()
    nvim('command', "let $VAR = 'abc'")
    if iswin() then
      nvim('command', "let j = jobstart('echo $env:VAR', g:job_opts)")
    else
      nvim('command', "let j = jobstart('echo $VAR', g:job_opts)")
    end
    eq({'notification', 'stdout', {0, {'abc', ''}}}, next_msg())
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('changes to given / directory', function()
    nvim('command', "let g:job_opts.cwd = '/'")
    if iswin() then
      nvim('command', "let j = jobstart('pwd|%{$_.Path}', g:job_opts)")
    else
      nvim('command', "let j = jobstart('pwd', g:job_opts)")
    end
    eq({'notification', 'stdout',
      {0, {(iswin() and [[C:\]] or '/'), ''}}}, next_msg())
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('changes to given `cwd` directory', function()
    local dir = eval('resolve(tempname())')
    mkdir(dir)
    nvim('command', "let g:job_opts.cwd = '" .. dir .. "'")
    if iswin() then
      nvim('command', "let j = jobstart('pwd|%{$_.Path}', g:job_opts)")
    else
      nvim('command', "let j = jobstart('pwd', g:job_opts)")
    end
    eq({'notification', 'stdout', {0, {dir, ''}}}, next_msg())
    eq({'notification', 'exit', {0, 0}}, next_msg())
    rmdir(dir)
  end)

  it('fails to change to invalid `cwd`', function()
    local dir = eval('resolve(tempname())."-bogus"')
    local _, err = pcall(function()
      nvim('command', "let g:job_opts.cwd = '" .. dir .. "'")
      if iswin() then
        nvim('command', "let j = jobstart('pwd|%{$_.Path}', g:job_opts)")
      else
        nvim('command', "let j = jobstart('pwd', g:job_opts)")
      end
    end)
    ok(string.find(err, "E475: Invalid argument: expected valid directory$") ~= nil)
  end)

  it('returns 0 when it fails to start', function()
    eq("", eval("v:errmsg"))
    execute("let g:test_jobid = jobstart([])")
    eq(0, eval("g:test_jobid"))
    eq("E474:", string.match(eval("v:errmsg"), "E%d*:"))
  end)

  it('returns -1 when target is not executable #5465', function()
    if helpers.pending_win32(pending) then return end
    local function new_job()
      return eval([[jobstart('')]])
    end
    local executable_jobid = new_job()
    local nonexecutable_jobid = eval(
      "jobstart(['./test/functional/fixtures/non_executable.txt'])")
    eq(-1, nonexecutable_jobid)
    -- Should _not_ throw an error.
    eq("", eval("v:errmsg"))
    -- Non-executable job should not increment the job ids. #5465
    eq(executable_jobid + 1, new_job())
  end)

  it('invokes callbacks when the job writes and exits', function()
    -- TODO: hangs on Windows
    if helpers.pending_win32(pending) then return end
    nvim('command', "call jobstart('echo', g:job_opts)")
    eq({'notification', 'stdout', {0, {'', ''}}}, next_msg())
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('allows interactive commands', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    neq(0, eval('j'))
    nvim('command', 'call jobsend(j, "abc\\n")')
    eq({'notification', 'stdout', {0, {'abc', ''}}}, next_msg())
    nvim('command', 'call jobsend(j, "123\\nxyz\\n")')
    eq({'notification', 'stdout', {0, {'123', 'xyz', ''}}}, next_msg())
    nvim('command', 'call jobsend(j, [123, "xyz", ""])')
    eq({'notification', 'stdout', {0, {'123', 'xyz', ''}}}, next_msg())
    nvim('command', "call jobstop(j)")
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('preserves NULs', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    -- Make a file with NULs in it.
    local filename = helpers.tmpname()
    write_file(filename, "abc\0def\n")

    nvim('command', "let j = jobstart(['cat', '"..filename.."'], g:job_opts)")
    eq({'notification', 'stdout', {0, {'abc\ndef', ''}}}, next_msg())
    eq({'notification', 'exit', {0, 0}}, next_msg())
    os.remove(filename)

    -- jobsend() preserves NULs.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', [[call jobsend(j, ["123\n456",""])]])
    eq({'notification', 'stdout', {0, {'123\n456', ''}}}, next_msg())
    nvim('command', "call jobstop(j)")
  end)

  it("will not buffer data if it doesn't end in newlines", function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    if os.getenv("TRAVIS") and os.getenv("CC") == "gcc-4.9"
      and helpers.os_name() == "osx" then
      -- XXX: Hangs Travis macOS since e9061117a5b8f195c3f26a5cb94e18ddd7752d86.
      pending("[Hangs on Travis macOS. #5002]", function() end)
      return
    end

    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', 'call jobsend(j, "abc\\nxyz")')
    eq({'notification', 'stdout', {0, {'abc', 'xyz'}}}, next_msg())
    nvim('command', "call jobstop(j)")
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('preserves newlines', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', 'call jobsend(j, "a\\n\\nc\\n\\n\\n\\nb\\n\\n")')
    eq({'notification', 'stdout',
      {0, {'a', '', 'c', '', '', '', 'b', '', ''}}}, next_msg())
  end)

  it('preserves NULs', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', 'call jobsend(j, ["\n123\n", "abc\\nxyz\n", ""])')
    eq({'notification', 'stdout', {0, {'\n123\n', 'abc\nxyz\n', ''}}},
      next_msg())
    nvim('command', "call jobstop(j)")
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('avoids sending final newline', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', 'call jobsend(j, ["some data", "without\nfinal nl"])')
    eq({'notification', 'stdout', {0, {'some data', 'without\nfinal nl'}}},
      next_msg())
    nvim('command', "call jobstop(j)")
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it('closes the job streams with jobclose', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', 'call jobclose(j, "stdin")')
    eq({'notification', 'exit', {0, 0}}, next_msg())
  end)

  it("disallows jobsend on a job that closed stdin", function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    nvim('command', 'call jobclose(j, "stdin")')
    eq(false, pcall(function()
      nvim('command', 'call jobsend(j, ["some data"])')
    end))
  end)

  it('disallows jobsend/stop on a non-existent job', function()
    eq(false, pcall(eval, "jobsend(-1, 'lol')"))
    eq(false, pcall(eval, "jobstop(-1)"))
  end)

  it('disallows jobstop twice on the same job', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    neq(0, eval('j'))
    eq(true, pcall(eval, "jobstop(j)"))
    eq(false, pcall(eval, "jobstop(j)"))
  end)

  it('will not leak memory if we leave a job running', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "call jobstart(['cat', '-'], g:job_opts)")
  end)

  it('can get the pid value using getpid', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    nvim('command', "let j =  jobstart(['cat', '-'], g:job_opts)")
    local pid = eval('jobpid(j)')
    eq(0,os.execute('ps -p '..pid..' > /dev/null'))
    nvim('command', 'call jobstop(j)')
    eq({'notification', 'exit', {0, 0}}, next_msg())
    neq(0,os.execute('ps -p '..pid..' > /dev/null'))
  end)

  it("do not survive the exit of nvim", function()
    if helpers.pending_win32(pending) then return end
    -- use sleep, which doesn't die on stdin close
    nvim('command', "let g:j =  jobstart(['sleep', '1000'], g:job_opts)")
    local pid = eval('jobpid(g:j)')
    eq(0,os.execute('ps -p '..pid..' > /dev/null'))
    clear()
    neq(0,os.execute('ps -p '..pid..' > /dev/null'))
  end)

  it('can survive the exit of nvim with "detach"', function()
    if helpers.pending_win32(pending) then return end
    nvim('command', 'let g:job_opts.detach = 1')
    nvim('command', "let g:j = jobstart(['sleep', '1000'], g:job_opts)")
    local pid = eval('jobpid(g:j)')
    eq(0,os.execute('ps -p '..pid..' > /dev/null'))
    clear()
    eq(0,os.execute('ps -p '..pid..' > /dev/null'))
    -- clean up after ourselves
    os.execute('kill -9 '..pid..' > /dev/null')
  end)

  it('can pass user data to the callback', function()
    nvim('command', 'let g:job_opts.user = {"n": 5, "s": "str", "l": [1]}')
    nvim('command', [[call jobstart('echo "foo"', g:job_opts)]])
    local data = {n = 5, s = 'str', l = {1}}
    eq({'notification', 'stdout', {data, {'foo', ''}}}, next_msg())
    eq({'notification', 'exit', {data, 0}}, next_msg())
  end)

  it('can omit options', function()
    if helpers.pending_win32(pending) then return end
    neq(0, nvim('eval', 'delete(".Xtestjob")'))
    nvim('command', "call jobstart(['touch', '.Xtestjob'])")
    nvim('command', "sleep 100m")
    eq(0, nvim('eval', 'delete(".Xtestjob")'))
  end)

  it('can omit data callbacks', function()
    nvim('command', 'unlet g:job_opts.on_stdout')
    nvim('command', 'unlet g:job_opts.on_stderr')
    nvim('command', 'let g:job_opts.user = 5')
    nvim('command', [[call jobstart('echo "foo"', g:job_opts)]])
    eq({'notification', 'exit', {5, 0}}, next_msg())
  end)

  it('can omit exit callback', function()
    nvim('command', 'unlet g:job_opts.on_exit')
    nvim('command', 'let g:job_opts.user = 5')
    nvim('command', [[call jobstart('echo "foo"', g:job_opts)]])
    eq({'notification', 'stdout', {5, {'foo', ''}}}, next_msg())
  end)

  it('will pass return code with the exit event', function()
    nvim('command', 'let g:job_opts.user = 5')
    nvim('command', "call jobstart('exit 55', g:job_opts)")
    eq({'notification', 'exit', {5, 55}}, next_msg())
  end)

  it('can receive dictionary functions', function()
    source([[
    let g:dict = {'id': 10}
    function g:dict.on_exit(id, code, event)
      call rpcnotify(g:channel, a:event, a:code, self.id)
    endfunction
    call jobstart('exit 45', g:dict)
    ]])
    eq({'notification', 'exit', {45, 10}}, next_msg())
  end)

  it('can redefine callbacks being used by a job', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    local screen = Screen.new()
    screen:attach()
    screen:set_default_attr_ids({
      [1] = {bold=true, foreground=Screen.colors.Blue},
    })
    source([[
      function! g:JobHandler(job_id, data, event)
      endfunction

      let g:callbacks = {
      \ 'on_stdout': function('g:JobHandler'),
      \ 'on_stderr': function('g:JobHandler'),
      \ 'on_exit': function('g:JobHandler')
      \ }
      let job = jobstart('cat -', g:callbacks)
    ]])
    wait()
    source([[
      function! g:JobHandler(job_id, data, event)
      endfunction
    ]])

    eq("", eval("v:errmsg"))
  end)

  it('requires funcrefs for script-local (s:) functions', function()
    -- Pass job callback names _without_ `function(...)`.
    source([[
      function! s:OnEvent(id, data, event) dict
        let g:job_result = get(self, 'user')
      endfunction
      let s:job = jobstart('echo "foo"', {
        \ 'on_stdout': 's:OnEvent',
        \ 'on_stderr': 's:OnEvent',
        \ 'on_exit':   's:OnEvent',
        \ 'user': 2349
        \ })
    ]])

    -- The behavior is asynchronous, retry until a time limit.
    helpers.retry(nil, 10000, function()
      eq("E120:", string.match(eval("v:errmsg"), "E%d*:"))
    end)
  end)

  it('does not repeat output with slow output handlers', function()
    if helpers.pending_win32(pending) then return end
    source([[
      let d = {'data': []}
      function! d.on_stdout(job, data, event) dict
        call add(self.data, a:data)
        sleep 200m
      endfunction
      if has('win32')
        let cmd = '1,2,3,4,5 | foreach-object -process {echo $_; sleep 0.1}'
      else
        let cmd = ['sh', '-c', 'for i in $(seq 1 5); do echo $i; sleep 0.1; done']
      endif
      call jobwait([jobstart(cmd, d)])
      call rpcnotify(g:channel, 'data', d.data)
    ]])
    eq({'notification', 'data', {{{'1', ''}, {'2', ''}, {'3', ''}, {'4', ''}, {'5', ''}}}}, next_msg())
  end)

  it('jobstart() works with partial functions', function()
    source([[
    function PrintArgs(a1, a2, id, data, event)
      " Windows: remove ^M
      let normalized = map(a:data, 'substitute(v:val, "\r", "", "g")')
      call rpcnotify(g:channel, '1', a:a1,  a:a2, normalized, a:event)
    endfunction
    let Callback = function('PrintArgs', ["foo", "bar"])
    let g:job_opts = {'on_stdout': Callback}
    call jobstart('echo "some text"', g:job_opts)
    ]])
    eq({'notification', '1', {'foo', 'bar', {'some text', ''}, 'stdout'}}, next_msg())
  end)

  describe('jobwait', function()
    it('returns a list of status codes', function()
      source([[
      call rpcnotify(g:channel, 'wait', jobwait([
      \  jobstart('sleep 0.10; exit 4'),
      \  jobstart('sleep 0.110; exit 5'),
      \  jobstart('sleep 0.210; exit 6'),
      \  jobstart('sleep 0.310; exit 7')
      \  ]))
      ]])
      eq({'notification', 'wait', {{4, 5, 6, 7}}}, next_msg())
    end)

    it('will run callbacks while waiting', function()
      source([[
      let g:dict = {'id': 10}
      let g:exits = 0
      function g:dict.on_exit(id, code, event)
        if a:code != 5
          throw 'Error!'
        endif
        let g:exits += 1
      endfunction
      call jobwait([
      \  jobstart('sleep 0.010; exit 5', g:dict),
      \  jobstart('sleep 0.030; exit 5', g:dict),
      \  jobstart('sleep 0.050; exit 5', g:dict),
      \  jobstart('sleep 0.070; exit 5', g:dict)
      \  ])
      call rpcnotify(g:channel, 'wait', g:exits)
      ]])
      eq({'notification', 'wait', {4}}, next_msg())
    end)

    it('will return status codes in the order of passed ids', function()
      source([[
      call rpcnotify(g:channel, 'wait', jobwait([
      \  jobstart('sleep 0.070; exit 4'),
      \  jobstart('sleep 0.050; exit 5'),
      \  jobstart('sleep 0.030; exit 6'),
      \  jobstart('sleep 0.010; exit 7')
      \  ]))
      ]])
      eq({'notification', 'wait', {{4, 5, 6, 7}}}, next_msg())
    end)

    it('will return -3 for invalid job ids', function()
      source([[
      call rpcnotify(g:channel, 'wait', jobwait([
      \  -10,
      \  jobstart('sleep 0.01; exit 5'),
      \  ]))
      ]])
      eq({'notification', 'wait', {{-3, 5}}}, next_msg())
    end)

    it('will return -2 when interrupted', function()
      execute('call rpcnotify(g:channel, "ready") | '..
              'call rpcnotify(g:channel, "wait", '..
              'jobwait([jobstart("sleep 10; exit 55")]))')
      eq({'notification', 'ready', {}}, next_msg())
      feed('<c-c>')
      eq({'notification', 'wait', {{-2}}}, next_msg())
    end)

    it('can be called recursively', function()
      if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
      source([[
      let g:opts = {}
      let g:counter = 0
      function g:opts.on_stdout(id, msg, _event)
        if self.state == 0
          if self.counter < 10
            call Run()
          endif
          let self.state = 1
          call jobsend(a:id, "line1\n")
        elseif self.state == 1
          let self.state = 2
          call jobsend(a:id, "line2\n")
        elseif self.state == 2
          let self.state = 3
          call jobsend(a:id, "line3\n")
        else
          call rpcnotify(g:channel, 'w', printf('job %d closed', self.counter))
          call jobclose(a:id, 'stdin')
        endif
      endfunction
      function g:opts.on_exit(...)
        call rpcnotify(g:channel, 'w', printf('job %d exited', self.counter))
      endfunction
      function Run()
        let g:counter += 1
        let j = copy(g:opts)
        let j.state = 0
        let j.counter = g:counter
        call jobwait([
        \   jobstart('echo ready; cat -', j),
        \ ])
      endfunction
      ]])
      execute('call Run()')
      local r
      for i = 10, 1, -1 do
        r = next_msg()
        eq('job '..i..' closed', r[3][1])
        r = next_msg()
        eq('job '..i..' exited', r[3][1])
      end
      eq(10, nvim('eval', 'g:counter'))
    end)

    describe('with timeout argument', function()
      if helpers.pending_win32(pending) then return end
      it('will return -1 if the wait timed out', function()
        source([[
        call rpcnotify(g:channel, 'wait', jobwait([
        \  jobstart('exit 4'),
        \  jobstart('sleep 10; exit 5'),
        \  ], 100))
        ]])
        eq({'notification', 'wait', {{4, -1}}}, next_msg())
      end)

      it('can pass 0 to check if a job exists', function()
        source([[
        call rpcnotify(g:channel, 'wait', jobwait([
        \  jobstart('sleep 0.05; exit 4'),
        \  jobstart('sleep 0.3; exit 5'),
        \  ], 0))
        ]])
        eq({'notification', 'wait', {{-1, -1}}}, next_msg())
      end)
    end)
  end)

  -- FIXME need to wait until jobsend succeeds before calling jobstop
  pending('will only emit the "exit" event after "stdout" and "stderr"', function()
    nvim('command', "let j = jobstart(['cat', '-'], g:job_opts)")
    local jobid = nvim('eval', 'j')
    nvim('eval', 'jobsend(j, "abcdef")')
    nvim('eval', 'jobstop(j)')
    eq({'notification', 'j', {0, {jobid, 'stdout', {'abcdef'}}}}, next_msg())
    eq({'notification', 'j', {0, {jobid, 'exit'}}}, next_msg())
  end)

  it('cannot have both rpc and pty options', function()
    if helpers.pending_win32(pending) then return end  -- TODO: Need `cat`.
    command("let g:job_opts.pty = v:true")
    command("let g:job_opts.rpc = v:true")
    local _, err = pcall(command, "let j = jobstart(['cat', '-'], g:job_opts)")
    ok(string.find(err, "E475: Invalid argument: job cannot have both 'pty' and 'rpc' options set") ~= nil)
  end)

  describe('running tty-test program', function()
    if helpers.pending_win32(pending) then return end
    local function next_chunk()
      local rv
      while true do
        local msg = next_msg()
        local data = msg[3][2]
        for i = 1, #data do
          data[i] = data[i]:gsub('\n', '\000')
        end
        rv = table.concat(data, '\n')
        rv = rv:gsub('\r\n$', ''):gsub('^\r\n', '')
        if rv ~= '' then
          break
        end
      end
      return rv
    end

    local function send(str)
      nvim('command', 'call jobsend(j, "'..str..'")')
    end

    before_each(function()
      -- Redefine Normalize() so that TTY data is not munged.
      source([[
      function! Normalize(data) abort
        return a:data
      endfunction
      ]])
      local ext = iswin() and '.exe' or ''
      insert(nvim_dir..'/tty-test'..ext)  -- Full path to tty-test.
      nvim('command', 'let g:job_opts.pty = 1')
      nvim('command', 'let exec = [expand("<cfile>:p")]')
      nvim('command', "let j = jobstart(exec, g:job_opts)")
      eq('tty ready', next_chunk())
    end)

    it('echoing input', function()
      send('test')
      eq('test', next_chunk())
    end)

    it('resizing window', function()
      nvim('command', 'call jobresize(j, 40, 10)')
      eq('rows: 10, cols: 40', next_chunk())
      nvim('command', 'call jobresize(j, 10, 40)')
      eq('rows: 40, cols: 10', next_chunk())
    end)

    it('jobclose() sends SIGHUP', function()
      nvim('command', 'call jobclose(j)')
      local msg = next_msg()
      msg = (msg[2] == 'stdout') and next_msg() or msg  -- Skip stdout, if any.
      eq({'notification', 'exit', {0, 42}}, msg)
    end)
  end)
end)

describe("pty process teardown", function()
  local screen
  before_each(function()
    clear()
    screen = Screen.new(30, 6)
    screen:attach()
    screen:expect([[
      ^                              |
      ~                             |
      ~                             |
      ~                             |
      ~                             |
                                    |
    ]])
  end)
  after_each(function()
    screen:detach()
  end)

  it("does not prevent/delay exit. #4798 #4900", function()
    if helpers.pending_win32(pending) then return end
    -- Use a nested nvim (in :term) to test without --headless.
    execute(":terminal '"..helpers.nvim_prog
      -- Use :term again in the _nested_ nvim to get a PTY process.
      -- Use `sleep` to simulate a long-running child of the PTY.
      .."' +terminal +'!(sleep 300 &)' +qa")

    -- Exiting should terminate all descendants (PTY, its children, ...).
    screen:expect([[
                                    |
      [Process exited 0]            |
                                    |
                                    |
                                    |
      -- TERMINAL --                |
    ]])
  end)
end)
