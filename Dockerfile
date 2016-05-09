FROM jackfirth/racket
MAINTAINER Pavel Panchekha <me@pavpanchekha.com>
RUN apt-get update \
 && apt-get install -y libcairo2-dev libjpeg62 libpango1.0-dev \
 && rm -rf /var/lib/apt/lists/*
ADD herbie /src/herbie
RUN raco pkg install --auto /src/herbie
ENTRYPOINT ["raco", "herbie"]
