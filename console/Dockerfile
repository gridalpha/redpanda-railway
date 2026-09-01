FROM redpandadata/console:latest

USER root

COPY entrypoint.sh /usr/local/bin/console-railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/console-railway-entrypoint.sh \
 && sh -n /usr/local/bin/console-railway-entrypoint.sh

USER redpandaconsole
WORKDIR /app

ENTRYPOINT ["/usr/local/bin/console-railway-entrypoint.sh"]
