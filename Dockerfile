FROM        perl:latest
MAINTAINER  Rick Dulton <sam.olsen11@gmail.com>

RUN cpanm --notest --configure-timeout=3600 POE::Component::IRC

COPY files/* /usr/src/strikebot/

WORKDIR /usr/src/strikebot

USER nobody
CMD [ "perl", "./strikebot.pl" ]