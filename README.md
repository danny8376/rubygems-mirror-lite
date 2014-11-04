# Rubygems Mirror LITE

This program can help to full mirror of a remote gems server (mainly [rubygems.org](http://rubygems.org)).
It's written with [EventMachine](http://rubyeventmachine.com), a ruby event-driven framework,
and consists of two parts -- a rubygems puller which keep sync with remote gems server and
a stub api server which implements dependencies api of rubygems.org.

Notice: This is a tool which is for pure mirroring only.
If you want a private gems server, please use other tools such as [Geminabox](https://github.com/geminabox/geminabox).
However, you can full mirror those private gems server with this tool.

# How it works

```
(Backend)
                -------------------------------
                |       Official Mirror        |
                -------------------------------
                              |
                         [HTTP GET]
                              |
              [Fetch *.4.8] -> [Store in local]
                              |
            [Parse *specs.4.8 to discover new gems]
                              |
                |--[loop fetch new gems/gemspecs] -----> [Store in local]
                |             |
                --------------|
                              |
            [All .gem/.gemspec.rz files fetched]
                              |
         [Update dependencies data from *.gemspec.rz]
                              |
                           [Done]


                                              [Dynamicly meerge dependencies data]
                                                                |
                        [Directly serve files] [reverse proxy to stub api server]
                                  |                             |
                        [Query for single gem]       [Query for mutiple gems]
                                  |                             |
                                  -------------------------------
                                                 |
           [reverse proxy back to source server] |
                             |                   |
                 [other than dependencies] [dependencies]
                             |                   |
    [Directly serve files]   ---------------------
              |                        |
[*.4.8/.gem/.gemspec.rz files]       [API]
              |                        |
              --------------------------
                           |
                     [Web server]
(Frontend)
```

## Requirements

Ruby libraries:

* rubygems
* eventmachine

System utilities:

* wget

## Usage

You may want to switch a dedicated user first.

    $ sudo su mirror_user

clone the source code to somewhere you like

    $ cd /path/to/where/you/like
    $ git clone

Then copy the mirror-conf.rb.example to mirror-conf.rb, and edit it as you want.

    $ cp mirror-conf.rb.example mirror-conf.rb
    $ vim mirror-conf.rb

After finishing editing, do the first sync.
This will take a long while, you may wish to use screen/tmux to run this command and
configure the webserver during wainting.

    $ ./rubygems-pull.rb

(There are some arguments for the rubygems-pull.rb script,
you can get more details in the header comments of that file.)

BTW, the size of full mirror of rubygems.org is about 150GB.

---

The above process only prepare files that will be used for a mirror.
You will need a web server to serve those files.

The following is for [nginx](http://nginx.org):

There is an example file at examples/nginx-server-example.conf

For nginx, we mostly serve files direct with nginx itself.
But for dependencies api, we use try_files to get some more performance.
Therefore, we must link dep_data folder into mirror folder (where we set as root path).
(I prefer to make it hidden since it's not file originally located here.)

    $ cd /path/to/mirror/folder/mirror
    $ ln -s ../dep_data .dep_data

After making this symbolic link, we can use try_files to directly serve single gem queries.

And the stub api server will be discussed later.

_There may be some more web server configurations._

---

For Rubygems itself, it uses only single gem query of dependencies api.
However, for [bundler](http://bundler.io/), it uses mutiple gems query.
Therefore, there is a stub api server for this purpose.

The stub api server is a ruby script that can run directly.

    $ cd /path/to/where/you/like
    $ ./rubygems-dep-api-server.rb

However, at most time, you won't want to run it manually.

You can write an init.d script for init systems, or a service file for systemd systems.

There is an example for systemd service file at examples/rubygems-dep-api-server.service

_There should be an example init.d script :P_

---

And finally, the first sync is done! (If it doesn't, you can wait it util done ^.< )

You may wish the sync process to be run automatically.
(It's also recommended to do so.)
For this purpose, you can write a crontab or systemd timer.

For crontab, just append the following line to /etc/crontab, making it run hourly.

    0 * * * *   mirror_user      /path/to/where/you/like/rubygems-pull.rb

The script will generate some output.
If you don't want your root's mailbox be bugged by those output.
You can redirect the stdout to /dev/null.

    0 * * * *   mirror_user      /path/to/where/you/like/rubygems-pull.rb > /dev/null

Or you may wish log it somewhere.

    0 * * * *   mirror_user      /path/to/where/you/like/rubygems-pull.rb > /path/to/log/folder/`date +\%Y_\%m_\%d_\%H_\%M`.log

_Maybe will add systemd timer later?_

## TODO

* Replace wget system call with EM-HTTP with stream file write.
  (I think this will remain TODO for a long while :P)

## Report bugs

If you find any bug, welcome to open an issue [here](https://github.com/danny8376/rubygems-mirror-lite/issues).

## Running mirror

* [gems.saru.moe](http://gems.saru.moe)
  My testing mirror at Taiwan, which is used for developing this program.

Welcome to put your mirror here :-)

## License

All source code in this repository is licensed under the MIT license unless
specified otherwise. A copy of this license can be found in the file "LICENSE"
in the root directory of this repository.
