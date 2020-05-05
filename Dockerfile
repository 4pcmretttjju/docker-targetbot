FROM        perl:latest
MAINTAINER  Rick Dulton <sam.olsen11@gmail.com>

RUN cpanm --notest --configure-timeout=3600 POE::Component::IRC

COPY files/* /usr/src/targetbot/

WORKDIR /usr/src/targetbot

USER nobody
CMD [ "perl", "./targetbot.pl" ]
