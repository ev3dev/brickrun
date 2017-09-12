brickrun
========

Command line tool for launching ev3dev programs.


Documentation
-------------

* [Online](doc/brickrun.rst)


Install
-------

    If you are running an ev3dev "stretch" image and yet Visual Studio Code reports
        brickrun: command not found
    you may need to install brickrun:
        sudo apt update && sudo apt install brickrun


Hacking
-------

    sudo apt update
    sudo apt install cmake pandoc valac
    git clone --recursive https://github.com/ev3dev/brickrun
    cd brickrun
    cmake -P setup.cmake
    make -C build
