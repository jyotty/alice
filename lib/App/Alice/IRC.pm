use MooseX::Declare;

class App::Alice::IRC {
  use feature ':5.10';
  use MooseX::POE::SweetArgs qw/event/;
  use Encode;
  use POE::Component::IRC;
  use POE::Component::IRC::State;
  use POE::Component::IRC::Plugin::Connector;
  use POE::Component::IRC::Plugin::CTCP;
  use POE::Component::IRC::Plugin::NickReclaim;

  has 'connection' => (
    is      => 'rw',
    default => sub {{}},
  );

  has 'alias' => (
    isa      => 'Str',
    is       => 'ro',
    required => 1,
  );
  
  has 'config' => (
    isa      => 'HashRef',
    is       => 'ro',
    lazy     => 1,
    default  => sub {shift->app->config},
  );

  has 'app' => (
    isa      => 'App::Alice',
    is       => 'ro',
    required => 1,
  );

  has 'prefix' => (
    isa      => 'Str',
    is       => 'rw',
    default  => '~&@%+',
  );

  has 'chantypes' => (
    isa      => 'Str',
    is       => 'rw',
    default  => '#&',
  );

  sub START {
    my $self = shift;
    if ($self->config->{ssl}) {
      eval { require POE::Component::SSLify };
      die "Missing module POE::Component::SSLify" if ($@);
    }
    my $irc = POE::Component::IRC::State->spawn(
      alias    => $self->alias,
      nick     => $self->config->{nick},
      ircname  => $self->config->{ircname},
      server   => $self->config->{host},
      port     => $self->config->{port},
      password => $self->config->{password},
      username => $self->config->{username},
      UseSSL   => $self->config->{ssl},
      msg_length => 1024,
    );
    $self->connection($irc);
    $self->add_plugins;
    $self->connection->yield(register => 'all');
    
    $self->app->send([$self->app->log_info($self->alias, "connecting")]);
    $self->connection->yield(connect => {});
  }
  
  method add_plugins {
    my $irc = $self->connection;
    $irc->{connector} = POE::Component::IRC::Plugin::Connector->new(
      delay => 20, reconnect => 10);
    $irc->plugin_add('Connector' => $irc->{connector});
    $irc->plugin_add('CTCP' => POE::Component::IRC::Plugin::CTCP->new(
      version => 'alice',
      userinfo => $irc->nick_name
    ));
    $irc->plugin_add('NickReclaim' => POE::Component::IRC::Plugin::NickReclaim->new());
  }

  method window (Str $title){
    $title = decode("utf8", $title, Encode::FB_WARN);
    my $window = $self->app->find_or_create_window($title, $self->connection);
    return $window;
  }

  event irc_001 => sub {
    my $self = shift;
    my @log;
    push @log, $self->app->log_info($self->alias, "connected");
    for (@{$self->config->{on_connect}}) {
      push @log, $self->app->log_info($self->alias, "sending $_");
      $self->connection->yield( quote => $_ );
    }
    for (@{$self->config->{channels}}) {
      push @log, $self->app->log_info($self->alias, "joining $_");
      $self->connection->yield( join => $_ );
    }
    $self->app->send(\@log);
  };
  
  event irc_005 => sub {
    my ($self, $server, $msg, $msglist) = @_;
    my ($chantypes) = ($msg =~ /CHANTYPES=([^\s]*)\s/);
    my ($prefix) = ($msg =~ /PREFIX=\([^)]*\)([^\s]*)\s/);
    $self->chantypes($chantypes) if $chantypes;
    $self->prefix($prefix) if $prefix;
    $self->app->send([$self->app->log_info($self->alias, $msg)]);
  };
  
  event irc_353 => sub {
    my ($self, $server, $msg, $msglist) = @_;
    $self->app->send([$self->app->log_info($self->alias, $msg)]);
    my $channel = $msglist->[1];
    my $window = $self->window($channel);
    for my $nick (split " ", $msglist->[2]) {
      my ($priv, $name) = (undef, $nick);
      my $prefix = $self->prefix;
      if ($nick =~ /^([$prefix])?(.+)/) {
        ($priv, $name) = ($1, $2);
      }
      $window->add_nick($name, $priv);
    }
  };
  
  event irc_366 => sub {
    my ($self, $server, $msg, $msglist) = @_;
    my $channel = $msglist->[0];
    my $window = $self->window($channel);
    my $topic = $window->topic;
    $self->app->send([
      $window->join_action,
      $window->render_event("topic", $topic->{SetBy}||"", $topic->{Value}||""),
    ]);
    $self->log_debug("requesting new tab for: $channel");
  };

  event irc_disconnected => sub {
    my $self = shift;
    $self->app->send([$self->app->log_info($self->alias, "disconnected")]);
  };

  event irc_public => sub {
    my ($self, $who, $where, $what) = @_;
    my $nick = ( split /!/, $who )[0];
    my $window = $self->window($where->[0]);
    $self->app->send([$window->render_message($nick, $what)]);
  };

  event irc_msg => sub {
    my ($self, $who, $recp, $what) = @_;
    my $nick = ( split /!/, $who)[0];
    my $window = $self->window($nick);
    $self->app->send([$window->render_message($nick, $what)]);
  };

  event irc_ctcp_action => sub {
    my ($self, $who, $where, $what) = @_;
    my $nick = ( split /!/, $who )[0];
    my $window = $self->window($where->[0]);
    $self->app->send([$window->render_message($nick, "• $what")]);
  };

  event irc_nick => sub {
    my ($self, $who, $new_nick) = @_;
    my $nick = ( split /!/, $who )[0];
    $self->app->send([
      map { $_->rename_nick($nick, $new_nick);
            $_->render_event("nick", $nick, $new_nick)
      } $self->app->nick_windows($nick)
    ]);
  };

  event irc_join => sub {
    my ($self, $who, $where) = @_;
    my $nick = ( split /!/, $who)[0];
    my $window = $self->window($where);
    if ($nick ne $self->connection->nick_name) {
      $window->add_nick($nick, undef);
      $self->app->send([$window->render_event("joined", $nick)]);
    }
  };

  event irc_part => sub {
    my ($self, $who, $where, $msg) = @_;
    my $nick = ( split /!/, $who)[0];
    my $window = $self->window($where);
    if ($nick eq $self->connection->nick_name) {
      $self->app->close_window($window);
      return;
    }
    $window->remove_nick($nick);
    $self->app->send([$window->render_event("left", $nick, $msg)]);
  };

  event irc_quit => sub {
    my ($self, $who, $msg, $channels) = @_;
    my $nick = ( split /!/, $who)[0];
    my @events = map {
      my $window = $self->window($_);
      $window->remove_nick($nick);
      $window->render_event("left", $nick, $msg);
    } @$channels;
    $self->app->send(\@events);
  };
  
  event irc_invite => sub {
    my ($self, $who, $where) = @_;
    my $nick = ( split /!/, $who)[0];
    $self->app->send([
      $self->app->log_info($self->alias, "$nick has invited you to join $where"),
      $self->app->render_notice("invite", $nick, $where)
    ]);
  };

  event irc_topic => sub {
    my ($self, $who, $channel, $topic) = @_;
    my $nick = (split /!/, $who)[0];
    my $window = $self->window($channel);
    $self->app->send([$window->render_event("topic", $nick, $topic)]);
  };

  sub log_debug {
    my $self = shift;
    say STDERR join " ", @_ if $self->config->{debug};
  }
}
