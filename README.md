# Docker Urbandead TargetBot

Docker image containing utils for **TargetBot** - an evolution of [strikebot](https://github.com/mitcdh/docker-strikebot), the one true papa of the [Ridleybank Resistance Front](http://wiki.urbandead.com/index.php/The_Ridleybank_Resistance_Front) and also a generic IRC bot for coordinating zombie strikes on [urbandead.com](urbandead.com)

### Environment Variables

* `NICK`: Username/IRC Name/Nick 
* `NS_PASS`: Nickserv password
* `SERVER`: IRC server to connect to
* `OWNER_CHANNELS`: Prints all stored targets to these channels
* `CHANNELS`: Comma deliminated list of auto-join channels and optional passwords


### Usage
````bash
docker run -d \
    --name targetbot \
    -e NICK="TargetBot" \
    -e NS_PASS="" \
    -e SERVER="irc.nexuswar.com" \
    -e OWNER_CHANNELS="#rrf-wc" \
    -e CHANNELS="#rrf-ud,#rrf-wc PASSWORD,#gore PASSWORD,#constable" \
    4pcmretttjju/docker-targetbot
````

### Structure
* `/usr/src/targetbot`: TargetBot's home

