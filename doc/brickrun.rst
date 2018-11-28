========
brickrun
========

:Author: David Lechner
:Date: August 2017


NAME
====

brickrun - Tool to run ev3dev programs on a remote virtual console.


SYNOPSIS
========

**brickrun** [**--directory=**\ *dir*] [**--redirect**] [**--**] *command* [*arg* ...]]


DESCRIPTION
===========

The **brickrun** command is used to run programs on ev3dev device. It takes
care of things like console switching and stopping motors in case your program
crashes.


OPTIONS
=======

*command*
    The command to run remotely on the **conrun-server**.

*arg* ...
    Additional arguments for *command*.

**-d**, **--directory=**\ *dir*
    Specifies the working directory for the remote command. When omitted, the
    current working directory of the **brickrun** command is used.

**-r**, **--redirect**
    When this flag is given, stdin and stdout will be redirected to the calling
    terminal. When omitted, stdin and stdout are attached to the remote console.
    Note: stderr is always redirected to the calling terminal.

**-h**, **--help**
    Print a help message and exit.

**-v**, **--version**
    Print the program version and exit.

**--**
    Separates *command* from other options. It is only needed when any *arg*
    contains flags starting with ``-``.


ENVIRONMENT
===========

**brickrun** sends the current environment to **conrun-server** so that *command*
executes using the environment of **brickrun** rather than **conrun-server**.


FILES
=====

**/etc/brickrun.conf**
    Optional configuration file. Each section is optional. Example::

        [status-leds]
        color=green

        [stop-button]
        dev_path=/dev/input/by-path/platform-gpio_keys-event
        key_code=14


SEE ALSO
========

**console-runner**\ (1)
