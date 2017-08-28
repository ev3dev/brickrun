/*
 * brickrun.vala
 *
 * Copyright (c) 2017 David Lechner <david@lechnology.com>
 * This file is part of console-runner.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

static int exitCode = 1;
static ConsoleRunner client;
static MainLoop loop;
static string[] command;

static string? directory = null;
static bool version = false;

const OptionEntry[] options = {
    { "directory" , 'd', 0, OptionArg.STRING, ref directory, "Specifies the working directory", "<dir>" },
    { "version", 'v', 0, OptionArg.NONE, ref version, "Display version number and exit", null },
    { null }
};

const string extra_parameters = "[--] <command> [<args>...]";
const string summary = "Runs a command remotely via console-runner-server.";
const string description = "Note: If <args>... contains any command line options starting with '-', then it is necessary to use '--'.";

static bool on_unix_signal (int sig) {
    // signals are passed to the remote process
    try {
        client.signal (sig);
    }
    catch (ConsoleRunnerError e) {
        critical ("Failed to send signal: %s\n", e.message);
    }
    catch (DBusError e) {
        if (e is DBusError.SERVICE_UNKNOWN) {
            stderr.printf ("lost connection to console-runner-service\n");
            loop.quit ();
            return Source.REMOVE;
        }
        critical ("Failed to send signal: %s\n", e.message);
    }

    return Source.CONTINUE;
}

static void on_bus_name_appeared (DBusConnection connection, string name, string name_owner) {
    try {
        client = Bus.get_proxy_sync<ConsoleRunner> (BusType.SYSTEM, name,
            console_runner_server_object_path,
            DBusProxyFlags.DO_NOT_AUTO_START);

        // After we call start(), one of these three signals will fire when the
        // process ends (or failed to start).
        client.exited.connect ((c) => {
            exitCode = c;
            loop.quit ();
        });
        client.signaled.connect ((s) => {
            stderr.printf ("Remote process ended due to signal: %s\n", strsignal (s));
            loop.quit ();
        });
        client.errored.connect ((m) => {
            stderr.printf ("Error: %s\n", m);
            loop.quit ();
        });

        // capture signals to send to the remote process
        Unix.signal_add (Posix.SIGINT, () => on_unix_signal (Posix.SIGINT));
        Unix.signal_add (Posix.SIGHUP, () => on_unix_signal (Posix.SIGHUP));
        Unix.signal_add (Posix.SIGTERM, () => on_unix_signal (Posix.SIGTERM));

        // capture environment to send to the remote process
        var env = new HashTable<string, string> (str_hash, str_equal);
        foreach (var v in Environment.list_variables ()) {
            env[v] = Environment.get_variable (v);
        }

        // working directory
        var cwd = directory ?? Environment.get_current_dir ();

        // handle pipes
        var stdin_stream = new UnixInputStream (stdin.fileno (), false);
        var stdout_stream = new UnixOutputStream (stdout.fileno (), false);
        var stderr_stream = new UnixOutputStream (stderr.fileno (), false);

        // finally, start the remote process
        client.start (command, env, cwd, false, stdin_stream,
            false, stdout_stream, true, stderr_stream);
    }
    catch (Error e) {
        if (e is DBusError.SERVICE_UNKNOWN) {
            stderr.printf ("console-runner-service is not running\n");
        }
        else if (e is ConsoleRunnerError.BUSY) {
            stderr.printf ("console-runner-service is busy\n");
        }
        else if (e is ConsoleRunnerError.FAILED) {
            DBusError.strip_remote_error (e);
            stderr.printf ("Starting remote process failed: %s\n", e.message);
        }
        else {
            stderr.printf ("Unexpected error: %s\n", e.message);
        }
        loop.quit ();
    }
}

static void on_bus_name_vanished (DBusConnection connection, string name) {
    // we lost the d-bus connection, or there wasn't one to begin with
    stderr.printf ("console-runner-service is not running\n");
    loop.quit ();
}

static void set_sysattr_value (string path, string sysattr, string value) {
    var sysattr_path = Path.build_filename (path, sysattr);
    var file = Posix.FILE.open (sysattr_path, "w");
    if (file == null) {
        warning ("Failed to open '%s': %s", path, strerror (errno));
        return;
    }
    file.puts (value);
}

/*
 * Brick status indication is imitating the official LEGO firmware.
 * When a program is started, we blink the green LEDs. When a program
 * ends, we go back to solid green. (Or blue for BrickPi.)
 */
static void set_leds (List<GUdev.Device> leds, bool start) {
    foreach (var led in leds) {
        var name = led.get_name ();
        var path = led.get_sysfs_path ();

        // the color and function are encoded in the name, so we have to extract them.

        var last_colon = name.last_index_of (":");
        if (last_colon == -1) {
            continue;
        }
        var function = name.substring (last_colon + 1);
        if (function != "brick-status") {
            // we only care about brick-status LEDs.
            continue;
        }
        var color = name.rstr_len (last_colon, ":");
        if (color == null) {
            // this should not happen in practice
            continue;
        }
        last_colon = color.last_index_of (":");
        color = color[1:last_colon];

        // FIXME: If we have both green and blue leds, we should only use green.
        // Or, we need a platform-specific way of dealing with LEDs.
        if (color == "green" || color == "blue") {
            if (start) {
                set_sysattr_value (path, "trigger", "heartbeat");
            }
            else {
                set_sysattr_value (path, "trigger", "default-on");
            }
        }
        else {
            set_sysattr_value (path, "trigger", "none");
            set_sysattr_value (path, "brightness", "0");
        }
    }
}

static int main (string[] args) {
    Environment.set_prgname (Path.get_basename (args[0]));

    try {
        var context = new OptionContext (extra_parameters);
        context.set_help_enabled (true);
        context.set_summary (summary);
        context.add_main_entries (options, null);
        context.set_description (description);
        context.parse (ref args);
    }
    catch (OptionError e) {
        stderr.printf ("Error: %s\n", e.message);
        stdout.printf ("Run '%s --help' to see a full list of available command line options.\n", args[0]);
        return 0;
    }

    if (version) {
        stdout.printf ("%s: v%s\n", Environment.get_prgname (), brickrun_version);
        return 0;
    }

    command = args[1:args.length];
    if (command.length > 0 && command[0] == "--") {
        command = command[1:command.length];
    }
    if (command.length == 0) {
        stderr.printf ("Error: missing <command> argument\n");
        return 0;
    }

    var watch_id = Bus.watch_name (BusType.SYSTEM, console_runner_server_bus_name,
        BusNameWatcherFlags.NONE, on_bus_name_appeared, on_bus_name_vanished);

    var udev_client = new GUdev.Client ({ "leds", "tacho-motor", "dc-motor" });
    var leds = udev_client.query_by_subsystem ("leds");
    if (leds != null) {
        set_leds (leds, true);
    }

    loop = new MainLoop ();
    loop.run();

    if (leds != null) {
        set_leds (leds, false);
    }

    Bus.unwatch_name (watch_id);

    return exitCode;
}

// From console-runner/common.vala

const string console_runner_server_bus_name = "org.ev3dev.ConsoleRunner";
const string console_runner_server_object_path = "/org/ev3dev/ConsoleRunner/Server";

[DBus (name = "org.ev3dev.ConsoleRunner")]
public interface ConsoleRunner : Object {
    public abstract void start (string[] args, HashTable<string, string> env, string cwd,
        bool pipe_stdin, UnixInputStream stdin_stream,
        bool pipe_stdout, UnixOutputStream stdout_stream,
        bool pipe_stderr, UnixOutputStream stderr_stream) throws DBusError, ConsoleRunnerError;
    public abstract void signal (int sig) throws DBusError, ConsoleRunnerError;
    public signal void exited (int code);
    public signal void signaled (int code);
    public signal void errored (string msg);
}

[DBus (name = "org.ev3dev.ConsoleRunner.Error")]
public errordomain ConsoleRunnerError
{
    FAILED,
    INVALID_ARGUMENT,
    BUSY
}
