# Docker Urbandead TargetBot UTILS

Docker image containing utils for **TargetBot** - an evolution of [strikebot](https://github.com/mitcdh/docker-strikebot), the one true papa of the [Ridleybank Resistance Front](http://wiki.urbandead.com/index.php/The_Ridleybank_Resistance_Front) and also a generic IRC bot for coordinating zombie strikes on [urbandead.com](urbandead.com)

### Environment Variables

* `NICK`: Username/IRC Name/Nick 
* `NS_PASS`: Nickserv password
* `SERVER`: IRC server to connect to
* `CHANNELS`: Comma deliminated list of auto-join channels and optional passwords
* `DEBUG`: 0 or 1 to toggle verbose stdout logging


### Usage
````bash
docker run -d \
    --name targetbot-utils \
    -e NICK="TargetBot-utils" \
    -e NS_PASS="" \
    -e SERVER="irc.nexuswar.com" \
    -e CHANNELS="#targetbot-utils" \
    -e DEBUG=1
    4pcmretttjju/targetbot-utils
````

### Structure
* `/usr/src/targetbot`: TargetBot's home

