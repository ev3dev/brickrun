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


// config file implementation
namespace Config {
    private const string status_leds_group = "status-leds";
    private const string stop_button_group= "stop-button";

    public static string status_leds_color;
    public static string stop_button_dev_path;
    public static int stop_button_key_code = 0;
    public static int stop_button_delay = 0;

    public static void read () {
        try {
            var conf_file = new KeyFile ();
            conf_file.load_from_file ("/etc/brickrun.conf", KeyFileFlags.NONE);
            if (conf_file.has_group (status_leds_group)) {
                status_leds_color = conf_file.get_string (status_leds_group, "color");
            }
            if (conf_file.has_group (stop_button_group)) {
                stop_button_dev_path = conf_file.get_string (stop_button_group, "dev_path");
                stop_button_key_code = conf_file.get_integer (stop_button_group, "key_code");
                if (conf_file.has_key (stop_button_group, "delay")) {
                    stop_button_delay = conf_file.get_integer (stop_button_group, "delay");
                }
            }
        }
        catch (KeyFileError err) {
            warning ("Error loading /etc/brickrun.conf: %s", err.message);
        }
        catch (FileError err) {
            // conf file is optional, so only debug message
            debug ("Error opening /etc/brickrun.conf: %s", err.message);
        }
    }
}

static bool second_signal = false;

static bool on_unix_signal (int sig) {
    if (second_signal) {
        // No more Mr. Nice Guy after the first signal.
        sig = Posix.SIGKILL;
    }
    else {
        second_signal = true;
    }

    try {
        if (sig == Posix.SIGKILL) {
            // if we are killing, then kill all processes in the process group
            client.signal_group (sig);
        }
        else {
            // for other signals, we just send the signal to the primary process
            client.signal (sig);
        }
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
    catch (IOError e) {
        critical ("IO error while sending signal: %s\n", e.message);
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
static void set_leds (List<GUdev.Device>? leds, bool start) {
    if (leds == null) {
        return;
    }
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

        if (color == (Config.status_leds_color ?? "green")) {
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

static uint stop_button_timeout_id = 0;

static void watch_stop_button () {
    if (Config.stop_button_dev_path == null) {
        return;
    }
    try {
        var event_chan = new IOChannel.file (Config.stop_button_dev_path, "r");
        event_chan.set_encoding (null);
        event_chan.add_watch (IOCondition.IN, (s, c) => {
            if (c == IOCondition.HUP) {
                warning ("Lost button events");
                return Source.REMOVE;
            }
            try {
                // vala doesn't seem to have a good API for binary data.
                var buf = new char[sizeof(Linux.Input.Event)];
                size_t read;
                var ret = s.read_chars (buf, out read);
                if (ret == IOStatus.NORMAL) {
                    // It takes a couple steps to convert vala array to struct
                    void *ptr = &buf[0];
                    Linux.Input.Event *event = ptr;
                    if (event.type == Linux.Input.EV_KEY && event.code == Config.stop_button_key_code) {
                        // if stop button was pressed and timeout is not pending
                        if (stop_button_timeout_id == 0 && event.value == 1) {
                            // if no delay, send signal right now
                            if (Config.stop_button_delay == 0) {
                                on_unix_signal (Posix.SIGKILL);
                            }
                            // otherwise schedule signal after timeout
                            else {
                                stop_button_timeout_id = Timeout.add_seconds (Config.stop_button_delay, () => {
                                    on_unix_signal (Posix.SIGKILL);
                                    stop_button_timeout_id = 0;
                                    return Source.REMOVE;
                                });
                            }
                        }
                        // if stop button was released and timeout is pending
                        else if (stop_button_timeout_id != 0 && event.value == 0) {
                            // cancel the signal
                            Source.remove (stop_button_timeout_id);
                            stop_button_timeout_id = 0;
                        }
                    }
                }
            }
            catch (Error err) {

            }
            return Source.CONTINUE;
        });
    }
    catch (FileError err) {
        warning ("Failed to open stop button device: %s", err.message);
    }
    catch (IOChannelError err) {
        warning ("Error initializing stop button: %s", err.message);
    }
}

static void stop_motors (List<GUdev.Device>? motors, string command, string? stop_action = null) {
    if (motors == null) {
        return;
    }
    foreach (var motor in motors) {
        var path = motor.get_sysfs_path ();
        if (stop_action != null) {
            set_sysattr_value (path, "stop_action", stop_action);
        }
        set_sysattr_value (path, "command", command);
    }
}

static void stop_sound (List<GUdev.Device>? inputs) {
    if (inputs == null) {
        return;
    }
    foreach (var input in inputs) {
        if (!input.get_name ().has_prefix ("event")) {
            // we are only interested in event nodes
            continue;
        }
        var input_parent = input.get_parent_with_subsystem ("input", null);
        if (input_parent == null) {
            // this should not happen in practice
            continue;
        }
        var snd_cap = input_parent.get_sysfs_attr_as_int ("capabilities/snd");
        if ((snd_cap & Linux.Input.SND_TONE) == 0) {
            continue;
        }
        var path = input.get_device_file ();
        if (path == null) {
            // this should not happen in practice
            continue;
        }
        var file = Posix.FILE.open (path, "w");
        if (file == null) {
            warning ("Failed to open '%s': %s", path, strerror (errno));
            return;
        }
        // stop any tones that might be playing
        var tone = Linux.Input.Event() {
            type = Linux.Input.EV_SND,
            code = (ushort)Linux.Input.SND_TONE,
            value = 0
        };
        file.write (&tone, sizeof(Linux.Input.Event), 1);
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

    Config.read ();

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

    var udev_client = new GUdev.Client ({ "intput", "leds", "tacho-motor", "dc-motor", "servo-motor" });
    var leds = udev_client.query_by_subsystem ("leds");
    set_leds (leds, true);
    watch_stop_button();

    loop = new MainLoop ();
    loop.run();

    stop_motors (udev_client.query_by_subsystem ("tacho-motor"), "reset");
    stop_motors (udev_client.query_by_subsystem ("dc-motor"), "stop", "coast");
    stop_motors (udev_client.query_by_subsystem ("servo-motor"), "float");

    stop_sound (udev_client.query_by_subsystem ("input"));

    set_leds (leds, false);

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
        bool pipe_stderr, UnixOutputStream stderr_stream) throws DBusError, IOError, ConsoleRunnerError;
    public abstract void signal (int sig) throws DBusError, IOError, ConsoleRunnerError;
    public abstract void signal_group (int sig) throws DBusError, IOError, ConsoleRunnerError;
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
