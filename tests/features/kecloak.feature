@artemiscloud
Feature: Keycloak

  Scenario: Test keycloak artifacts
    When container is started
    Then run test -f /opt/amq/lib/keycloak-adapter-core*.jar in container once
    Then run test -f /opt/amq/lib/keycloak-commmon*.jar in container once
    Then run test -f /opt/amq/lib/keycloak-core*.jar in container once
