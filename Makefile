PACKAGE=trapeze
DEPS=rabbitmq-mochiweb rabbitmq-erlang-client
TEST_APPS=mochiweb rabbit_mochiweb trapeze
START_RABBIT_IN_TESTS=true

include ../include.mk
