# Interesting experiments

Below there are descriptions on how to reproduce some interesting experiments.
Alternatively you can look a the pregenerated logs.

After following the set-up instructions, just run with `make run`.

Note: logs are color coded:
- gray: follower log
- blue: candidate log
- green: leader log
- red: node halting

### Re-elections work reliably with crashing leaders

log: `output/crash_leader.html` (5 servers)

reproduce:

1. Go to line 7 in `leader.ex`.
2. Uncomment:
```
Monitor.halt(s, "Crash leader as soon as elected.")
```
3. This way a leader will crash immediately and other nodes will elect a new
leader.
4. Log shows a majority of leaders gets elected, and then the remaining servers
keep on becoming candiates and failing elections (e.g. if you run with 5 servers
you will see 3 leaders getting elected and crashing, and the remaining 2 servers
keeping on trying to be elected).

### Re-elections work reliably with slow leaders

log: `output/slow_leader.html` (5 servers)

reproduce:

1. Go to `dac.ex`.
2. Set `heartbeat_send_delay` to a value higher than `election_timeout`.
3. This way the elected leader will not send the heartbeat in time before other
servers increase the election term, starting a new election.
4. This force the slow leader to stepdown and become a follower again.
5. Then a new leader gets elected and the process repeats.

### Logs are consistent across servers

log: `output/checksums.html`

in the log:
- 5 servers, 5 clients (each sends 100 requests).
- all servers crashes after around 30 seconds (well after they are done processing client requests), printing a checksum of the
content of their logs.
- all checksums are equal, confirming that the log entries are the same and 
in the same order.

to reproduce:

1. Uncomment the debug statement at line 64 in monitor.ex. This will print
the checksum after the server crashes.
2. Make all servers crash around 30 seconds into the experiment (setting
`crash_servers` in `dac.ex`).
3. Logs should show the same checksum for all servers.

### Logs of correct processes are consistent even if leader crashes

log: `outptut/log_consistent_on_leader_crash.html` 

in the log:
- 5 servers, 5 clients (each sends 100 requests).
- Server 3 gets elected and crashes afer 15 seconds.
- Server 1 crashes after 10 seconds (but not relevant for the experiment).
- After server 3 crashes, server 4 is elected and responds to all the
remaining requests from the clients.
- At the end, non-crashed servers 2, 4 and 5 all have applied the 500
requests to the database, and the same chekcsum.

reproduce:

1. Make sure that `crash_servers` is set in `dac.ex`.
2. This will crash the specified servers after the given timeout. My setup was:
```
crash_servers: %{
  1 => 10_000,
  2 => 31_000,
  3 => 15_000,
  4 => 33_000,
  5 => 34_000,
}
```
3. Run a few times in order to make sure the first leader elected is going 
to crash (in the example log, server 3).
4. Logs show that all alive processes have handled all client requests, 
consistently (you can print out the checksum if you want, by uncommenting line
64 in `monitor.ex`).

### Log consistency with slow append replies

log: `output/slow_append_replies.html`

in the log:
- 5 servers, 5 clients (each tries to send 5 requests).
- Server 5 gets elected (interesting "double" election, see report).
- The clients start to send messages, but the followers are slow to respond
hence the leader takes a long time to commit and reply to clients.
- You can see from the log that 3 clients managed to send 5 messages while the
other 2 clients sent 3 and 4 (in comparison to the 500 requests fulfilled with
no delays, in the previous experiment).
- Note that how, at the end of the 40 seconds not all requests have been
processed by all followers yet!

reproduce:

1. Remove entries from `crash_servers` in `dac.ex`, to focus on the target
of the experiment.
2. set `append_reply_delay` to some value (in the sample log is 80 ms).
3. set `num_client_requests` to something small (in the sample log is 5).
4. Logs should look similar to the one in slow_append_replies.html.

### Log consistency with slow append replies, but high append rpc timeout

log: `output/slow_append_replies_high_timeout.html`

in the log:
- 5 servers, 5 clients (each tries to send 5 requests).
- Server 5 gets elected (interesting "double" election, see report).
- The clients start to send messages, and the followers are still slow to
respond, but not as much as in the previous experiment.

reproduce:

1. Follow the steps from the previous experiment, but also set
`append_entries_timeout` to a value higher than `append_reply_delay` (in 
the experiment they were respectively 100 and 80).

See report for why this performs better than the previous experiment.

### Heavy load

log: `output/heavy_load.html`

in the log:
- 10 servers, 5 clients (each sending 200 requests with only 10 
milliseconds of `client_sleep`).
- run for 300 seconds, clients stopping after 200 seconds.
- crash 4 out of 10 servers (to still allow a majority of servers to still
commit entries).
- All correct servers handle all the sent client requests, and have 
consistent logs (identical checksum).

to reproduce:
1. In the makefile, increase the `MAX_TIME`, `SERVERS` and `CLIENTS` as 
desired (you may also want to spawn more nodes, one node halting may bring 
down multiple nodes).
2. In `dac.ex`, increase `client_requests`, `client_stop`. Decrease 
`client_sleep`. Set `crash_server`; my configuration was:
```
crash_servers: %{
  1 => 20_000,
  2 => 40_000,
  3 => 60_000,
  4 => 80_000,
  # At the end.
  5 => 295_000,
  6 => 295_000,
  7 => 295_000,
  8 => 295_000,
  9 => 295_000,
  10 => 295_000,
}
```
3. Uncomment line 64 in `monitor.ex` if you want to see checksums upon halting.

