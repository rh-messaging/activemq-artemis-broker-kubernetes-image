@artemiscloud
Feature: Basic

  Scenario: Test if the broker starts
    When container is started with env
      | variable                   | value |
      | AMQ_USER                   | admin |
      | AMQ_PASSWORD               | admin |
    Then check that port 61616 is open
    Then run /home/jboss/broker/bin/artemis check queue --name TEST --produce 1000 --browse 1000 --consume 1000 --user admin --password admin in container and check its output contains Checks run: 3, Failures: 0, Errors: 0, Skipped: 0
    Then run stat --printf="%s" /home/jboss/broker/log/artemis.log in container and immediately check its output for 0

  Scenario: Test if SNI checks are disabled
    When container is started with env
      | variable                  | value |
      | AMQ_USER                  | admin |
      | AMQ_PASSWORD              | admin |
    Then file /home/jboss/broker/etc/bootstrap.xml should contain binding sniHostCheck="false" sniRequired="false
