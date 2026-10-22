# lock-trap

Proves: with_id_lock in bin/wo and bin/bug keeps the caller's EXIT trap, runs it if the locked section exits, and never outlives its lock.
