# Erlang/OTP 29's `sets` opacity makes Dialyzer reject MapSet values held in the WorkerPool state map.
[
  {"lib/muex/worker_pool.ex", :call_with_opaque}
]
