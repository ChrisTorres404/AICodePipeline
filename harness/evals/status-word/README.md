# status-word

Proves: the close-path status readers (both drivers and evidence-gate.py) read the status word right after the marker, so a suite path holding PASS, RUNNING or NOT EXECUTED cannot change a run's verdict, and all three dashes read.
