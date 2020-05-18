FROM        perl:5.30
MAINTAINER  Rick Dulton <sam.olsen11@gmail.com>

RUN cpanm --notest --configure-timeout=3600 POE::Component::IRC MediaWiki::API LWP::Protocol::https

COPY files/targetbot-utils.pl /usr/src/targetbot/
COPY files/mapdata.dat /usr/src/targetbot/

WORKDIR /usr/src/targetbot

USER nobody
CMD [ "perl", "./targetbot-utils.pl" ]