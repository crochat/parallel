# parallel

This script's purpose is to demonstrate multitasking capabilities in Bash.
To manage multiple background processes, we need to be able to use concurrent programming mechanisms as mutexes, schedulers, interrupts, shared memory resources...

For mutex, I've tried by using simple files, but it was slow and not very efficient (I've kept the code as comments).
I wanted to use system's semaphores for mutex, but as they're not directly available in CLI, I've made the choice to use
https://github.com/acbits/sema
