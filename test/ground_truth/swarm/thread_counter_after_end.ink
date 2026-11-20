// Found by the differential swarm run (P16.3): END resets the call stack but not its
// thread counter, which every generated choice advances.
VAR x = 1
Hello {x}
* A
  Picked
-> END
