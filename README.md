# Docker Urbandead TargetBot

Kubernetes version of **TargetBot** - an evolution of [strikebot](https://github.com/mitcdh/docker-strikebot), the one true papa of the [Ridleybank Resistance Front](http://wiki.urbandead.com/index.php/The_Ridleybank_Resistance_Front) and also a generic IRC bot for coordinating zombie strikes on [urbandead.com](urbandead.com)

### Environment Variables 

From targetbot-manifest.yaml

* `NICK`: Username/IRC Name/Nick 
* `NS_PASS`: Nickserv password
* `SERVER`: IRC server to connect to
* `OWNER_CHANNELS`: Prints all stored targets to these channels
* `CHANNELS`: Comma deliminated list of auto-join channels and optional passwords


### Usage
````bash
kubectl apply -f targetbot-manifest.yaml    
````

### Containers
* `targetbot-irc`: joins IRC channels and parses dumbwit URLs for map updates
* `targetbot-wiki`: updates wiki pages with map updates, e.g. [User:TargetReport/Ridleybank](http://wiki.urbandead.com/index.php/User:TargetReport/Ridleybank).
