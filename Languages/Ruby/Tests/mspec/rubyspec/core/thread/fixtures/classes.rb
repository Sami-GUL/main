unless defined? Channel
  require 'thread'
  class Channel < Queue
    alias receive shift
  end
end

module ThreadSpecs
  class Status
    attr_reader :thread, :inspect, :status
    def initialize(thread)
      @thread = thread
      @alive = thread.alive?
      @inspect = thread.inspect
      @status = thread.status
      @stop = thread.stop?
    end
    
    def alive?
      @alive
    end
    
    def stop?
      @stop
    end
  end

  def self.sleeping_thread
    Thread.new do
      begin
        sleep
        ScratchPad.record :woken
      rescue Object => e
        ScratchPad.record e
      end
    end
  end

  def self.running_thread
    Thread.new do
      begin
        loop {}
        ScratchPad.record :woken
      rescue Object => e
        ScratchPad.record e
      end
    end
  end
  
  def self.completed_thread
    Thread.new {}
  end
  
  def self.status_of_current_thread
    Thread.new { Status.new(Thread.current) }.value
  end
  
  def self.status_of_running_thread
    t = running_thread
    Thread.pass while t.status and t.status != "run"
    status = Status.new t
    t.kill
    t.join
    status
  end
  
  def self.status_of_completed_thread
    t = completed_thread
    t.join
    Status.new t
  end
  
  def self.status_of_sleeping_thread
    t = sleeping_thread
    Thread.pass while t.status and t.status != 'sleep'
    status = Status.new t
    t.run
    t.join
    status
  end
  
  def self.status_of_blocked_thread
    m = Mutex.new
    m.lock
    t = Thread.new { m.lock }
    Thread.pass while t.status and t.status != 'sleep'
    status = Status.new t
    m.unlock
    t.join
    status
  end
  
  def self.status_of_aborting_thread
    t = Thread.new { begin; sleep; ensure; Thread.pass; end }
    begin
      Thread.critical = true if Thread.respond_to? :critical
      Thread.pass while t.status and t.status != 'sleep'
      t.kill
      Status.new t
    ensure
      Thread.critical = false if Thread.respond_to? :critical
    end
  end
  
  def self.status_of_killed_thread
    t = Thread.new { sleep }
    Thread.pass while t.status and t.status != 'sleep'
    t.kill
    t.join
    Status.new t
  end
  
  def self.status_of_thread_with_uncaught_exception
    t = Thread.new { raise "error" }
    begin
      t.join
    rescue RuntimeError
    end
    Status.new t
  end
  
  def self.status_of_dying_running_thread
    status = nil
    t = dying_thread_ensures { status = Status.new Thread.current }     
    t.join
    status
  end
  
  def self.status_of_dying_sleeping_thread
    t = dying_thread_ensures { Thread.stop; }           
    Thread.pass while t.status and t.status != 'sleep'
    status = Status.new t
    t.wakeup
    t.join
    status
  end
  
  def self.dying_thread_ensures(kill_method_name=:kill)
    t = Thread.new do
      begin
        Thread.current.send(kill_method_name)
      ensure
        yield
      end
    end
  end
  
  def self.dying_thread_with_outer_ensure(kill_method_name=:kill)
    t = Thread.new do
      begin
        begin
          Thread.current.send(kill_method_name)
        ensure
          raise "In dying thread"
        end
      ensure
        yield
      end
    end
  end
    
  def self.join_dying_thread_with_outer_ensure(kill_method_name=:kill)
    t = dying_thread_with_outer_ensure(kill_method_name) { yield }
    lambda { t.join }.should raise_error(RuntimeError, "In dying thread")
    return t
  end
  
  def self.wakeup_dying_sleeping_thread(kill_method_name=:kill)
    t = ThreadSpecs.dying_thread_ensures(kill_method_name) { yield }
    Thread.pass while t.status and t.status != 'sleep'
    t.wakeup
    t.join
  end
  
  def self.critical_is_reset
    # Create another thread to verify that it can call Thread.critical=
    t = Thread.new do
      initial_critical = Thread.critical
      Thread.critical = true
      Thread.critical = false
      initial_critical == false && Thread.critical == false
    end
    v = t.value
    t.join
    v
  end

  def self.counter
    @@counter
  end
  
  def self.counter= c
    @@counter = c
  end
  
  def self.increment_counter(incr)
    incr.times do
      begin
        Thread.critical = true
        @@counter += 1
      ensure
        Thread.critical = false
      end
    end
  end

  def self.critical_thread1()
    Thread.critical = true
    Thread.current.key?(:thread_specs).should == false
  end
  
  def self.critical_thread2(isThreadStop)
    Thread.current[:thread_specs].should == 101
    Thread.critical.should == !isThreadStop
    if not isThreadStop
      Thread.critical = false
    end
  end
  
  def self.main_thread1(critical_thread, isThreadSleep, isThreadStop)
    # Thread.stop resets Thread.critical. Also, with native threads, the Thread.Stop may not have executed yet
    # since the main thread will race with the critical thread
    if not isThreadStop
      Thread.critical.should == true
    end
    critical_thread[:thread_specs] = 101
    if isThreadSleep or isThreadStop
      # Thread#wakeup calls are not queued up. So we need to ensure that the thread is sleeping before calling wakeup
      Thread.pass while critical_thread.status and critical_thread.status != "sleep"
      critical_thread.wakeup
    end
  end
  
  def self.main_thread2(critical_thread)
    Thread.pass # The join below seems to cause a deadlock with CRuby unless Thread.pass is called first
    critical_thread.join
    Thread.critical.should == false
  end

  def self.critical_thread_yields_to_main_thread(isThreadSleep=false, isThreadStop=false)        
    @@after_first_sleep = false
    
    critical_thread = Thread.new do
      Thread.pass while Thread.main.status and Thread.main.status != "sleep"
      critical_thread1()
      Thread.main.wakeup
      yield
      Thread.pass while @@after_first_sleep != true # Need to ensure that the next statement does not see the first sleep itself
      Thread.pass while Thread.main.status and Thread.main.status != "sleep"
      critical_thread2(isThreadStop)
      Thread.main.wakeup
    end
    
    sleep 5
    @@after_first_sleep = true
    main_thread1(critical_thread, isThreadSleep, isThreadStop)
    sleep 5
    main_thread2(critical_thread)
  end
  
  def self.create_critical_thread()
    critical_thread = Thread.new do
      Thread.critical = true
      yield
      Thread.critical = false
    end
    return critical_thread
  end
  
  def self.create_and_kill_critical_thread(passAfterKill=false)
    critical_thread = ThreadSpecs.create_critical_thread do
      Thread.current.kill
      if passAfterKill
        Thread.pass
      end
      ScratchPad.record("status=" + Thread.current.status)
    end
  end
end
