FROM        perl:latest
MAINTAINER  Rick Dulton <sam.olsen11@gmail.com>

RUN cpanm --notest --configure-timeout=3600 POE::Component::IRC HTML::TreeBuilder MediaWiki::API LWP::Protocol::https Date::Parse

COPY files/* /usr/src/targetbot/
RUN mkdir /usr/src/targetbot/TargetReport
RUN chown nobody: /usr/src/targetbot/TargetReport

WORKDIR /usr/src/targetbot

USER nobody
CMD [ "perl", "./targetbot.pl" ]