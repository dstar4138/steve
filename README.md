# Steve: 

##The Peer-to-Peer Fault-Tolerant Language-Agnostic Computation Dispatcher Over Pooled Self-Organizing Heterogenous Nodes
                            

As part of the Distributed Systems course at the Rochester Institute of 
Technology, our group started work on Steve, the peer-to-peer computation 
dispatcher. Steve was formed from the proposal for a system based on the general 
concept of distributed computation and meshnets. It's goal is to provide 
fault-tolerant computation for mobile and capability restricted devices. 

Steve consists of trusted but self-organizing nodes which maintain their own 
capability lists so that they can attempt computation requests or forward them 
on if unable. 

In other words, say you don't have a C++ compiler on your smart-phone, or you 
are running Linux but want to test your code on a Windows 7 OS running python
version 2.7. Steve can help you out. Tell him what to find and he'll ask around.
When he finds a friend that is capable of doing what you asked he'll let you 
know and he'll pass on the program or code to run. When the friend gets back to
him he'll forward the report to you.

### Features: ###

* _Fault-tolerant:_ Steve can have a lot of friends, and if more than one 
  friend can work on your code, then you can let them all have a go. Just 
  in case one is a no-show, the other's will still have your back. Also, 
  in case you are preoccupied, Steve and his friends have a great memory 
  and will let you know what the answer was when you next get a chance.

* _Language-Agnostic:_ Steve's friends don't all have to speak the same 
  language, as long as they all know how to look at a computation request.
  The request could be for a particular language, or even a particular 
  operating system.

* _Self-Organizing:_ Steve cares about the friends that do him favors. The 
  one's that don't or send him crap gifts, are dropped from his friends 
  list. In other-words, Steve maintains a reputation system and will lower
  the reputation of friends that send him code that makes him crash or 
  don't return results that others do.

* _Heterogenous:_ Steve isn't expecting all friends to be able to do 
  everything, in fact, Steve counts on the fact that he's so connected 
  to diverse people, that he can get different things done for you. In 
  his network of friends, being unique and useful is a good thing.

### Faults: ###

* _Trust:_ Steve only talks to his friends. He's clique'ish like that. To be
  a part of the group Steve will first ask other's opinion of you before
  ever talking to you. Whitelist first, then rely on reputation later. 
  This can be a problem, especially if a dynamic friend-base is desirable.

* _Security:_ I'm sorry... right now Steve's a loud mouth. The only real 
  security you have in letting Steve do your dirty work, is that he'll let you 
  tell him exactly how to do something. So if you want it sandboxed, he'll use 
  that damn sandbox.


From the feature and fault lists, you can decide if you want to give Steve a 
try. Check the Building and Deploying sections below. If you think you can 
add more features or remove some faults, send us a pull request and we'll take 
a look at it. 


## REQUIREMENTS: ##

The Steve Daemon has only been tested on Mac OS X and Debian Linux. The 
Windows platform is currently not supported. The Steve Daemon only needs a few 
things to get started:
    
* Erlang VM (minimum version R15B01)
* `libcap-dev` (for erlexec package, to monitor OS processes)

Steve is headless and will need an interface to interact with it. You can use
the Erlang shell, or the following GUI:

* [Xamarin Steve Client](https://github.com/pdg6868/SteveClient) - 
  Uses Xamarin library and can be built for several different platforms 
  including Android.


## BUILDING: ##

  There are two parts that need to be built, the Daemon service that runs in the
background, and the Client that you can use to connect and utilize the Daemon.
To build both and start working with them, make sure your system meets the 
requirements above and type `make`.
 
* To run the daemon type the following: `./bin/runerl.sh`

* And then once the shell opens type: `steve:start().`


## DEPLOYING: ##

We use the Rebar system to compile our Erlang application releases:

```
make all
```

This will create a 'rel' directory that has bundled Steve along with the Erlang
VM for transport, just zip/tar it up if you want to move it to another system.
To install Steve:

```
cd ~/bin
ln -s /pathToRel/rel/steve/bin/steve
```

Steve works like a service:

```
./bin/steve
Usage: steve {start|stop|restart|reboot|ping|console|attach} 
```

Once started you can `attach` to the running service and treat it like an 
Erlang shell to send commands to it.

