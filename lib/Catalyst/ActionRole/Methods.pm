package Catalyst::ActionRole::Methods;

use Moose::Role;

our $VERSION = '0.004';

around 'dispatch', sub {
    my $orig = shift;
    my $self = shift;
    my $c    = shift;

    my $return = $self->$orig($c, @_);
    my $rest_method = $self->name . "_" . uc( $c->request->method );
    my $sub_return = $self->_dispatch_rest_method( $c, $rest_method );

    return defined($sub_return) ? $sub_return : $return;
};

around 'list_extra_info' => sub {
  my ($orig, $self, @args) = @_;
  my @allowed_methods = $self->get_allowed_methods($self->class,undef,$self->name);
  return +{
    %{ $self->$orig(@args) }, 
    HTTP_METHODS => \@allowed_methods,
  };
};
 
sub _dispatch_rest_method {
    my $self        = shift;
    my $c           = shift;
    my $rest_method = shift;

    my $req         = $c->request;
    my $controller = $c->component( $self->class );
    my ($code, $name);
  
    # Common case, for foo_GET etc
    if ( $code = $controller->action_for($rest_method) ) {
      return $c->forward( $code,  $req->args ); # Forward to foo_GET if it's an action
    }
    elsif ($code = $controller->can($rest_method)) {
        $name = $rest_method; # Stash name and code to run 'foo_GET' like an action below.
    }
 
    # Generic handling for foo_*
    if (!$code) {
        my $code_action = {
            OPTIONS => sub {
                $name = $rest_method;
                $code = sub { $self->_return_options($self->name, @_) };
            },
            HEAD => sub {
              $rest_method =~ s{_HEAD$}{_GET}i;
              $self->_dispatch_rest_method($c, $rest_method);
            },
            default => sub {
                # Otherwise, not implemented.
                $name = $self->name . "_not_implemented";
                $code = $controller->can($name) # User method
                    # Generic not implemented
                    || sub { $self->_return_not_implemented($self->name, @_) };
            },
        };
        my ( $http_method, $action_name ) = ( $rest_method, $self->name );
        $http_method =~ s{\Q$action_name\E\_}{};
        my $respond = ($code_action->{$http_method}
                       || $code_action->{'default'})->();
        return $respond unless $name;
    }
 
    # localise stuff so we can dispatch the action 'as normal, but get
    # different stats shown, and different code run.
    # Also get the full path for the action, and make it look like a forward
    local $self->{code} = $code;
    my @name = split m{/}, $self->reverse;
    $name[-1] = $name;
    local $self->{reverse} = "-> " . join('/', @name);
 
    $c->execute( $self->class, $self, @{ $req->args } );
}
 
sub get_allowed_methods {
    my ( $self, $controller, $c, $name ) = @_;
    my $class = ref $controller || $controller;
    my %methods = (
      map { /^\Q$name\E\_(.+)$/ ? ( $1 => 1 ) : () }
        ($class->meta->get_all_method_names )
    );
    $methods{'HEAD'} = 1 if exists $methods{'GET'};
    delete $methods{'not_implemented'};
    sort keys %methods;
}
 
sub _return_options {
    my ( $self, $method_name, $controller, $c) = @_;
    my @allowed = $self->get_allowed_methods($controller, $c, $method_name);
    $c->response->status(204);
    $c->response->header( 'Allow' => @allowed ? \@allowed : '' );
}
 
sub _return_not_implemented {
    my ( $self, $method_name, $controller, $c ) = @_;
 
    my @allowed = $self->get_allowed_methods($controller, $c, $method_name);
    $c->response->content_type('text/html');
    $c->response->status(405);
    $c->response->header( 'Allow' => @allowed ? \@allowed : '' );
    $c->response->body( '<!DOCTYPE html><title>405 Method Not Allowed</title><p>The requested method '
        . $c->request->method . ' is not allowed for this URL.</p>' );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Catalyst::ActionRole::Methods - Dispatch by HTTP Methods

=head1 SYNOPSIS

    package MyApp::Controller::Example;

    use Moose;
    use MooseX::MethodAttributes;

    extends 'Catalyst::Controller';

    sub myaction :Chained(/) Does('Methods') CaptureArgs(1) {
      my ($self, $c, $arg) = @_;
      # When this action is matched, first execute this action's
      # body, then an action matching the HTTP method or the not
      # implemented one if needed.
    }

      sub myaction_GET :Action {
        my ($self, $c, $arg) = @_;
        # Note that if the 'parent' action has args or capture-args, those are
        # made available to a matching method action.
      }

      sub myaction_POST {
        my ($self, $c, $arg) = @_;
        # We match the subroutine name whether its an action or not.  If you
        # make it an action, as in the _GET above, you are allowed to apply
        # action roles (which is the main advantage to this AFAIK).
      }

      sub myaction_not_implemented {
        my ($self, $c, $arg) = @_;
        # There's a sane default for this, but you can override as needed.
      }

      sub next_action_in_chain_1 :Chained(myaction) Args(0) { ... }

      sub next_action_in_chain_2 :Chained(myaction) Args(0) { ... }

    __PACKAGE__->meta->make_immutable;

=head1 DESCRIPTION

This is a L<Moose::Role> version of the classic L<Catalyst::Action::REST> action
class.  The intention is to offer some of the popular functionality that comes
with L<Catalyst::Action::REST> in a more modular, 'build what you need' package.

Bulk of this documentation and test cases derive from L<Catalyst::Action::REST>
with the current author's gratitude.

This Action Role handles doing automatic method dispatching for requests.  It
takes a normal Catalyst action, and changes the dispatch to append an
underscore and method name.  First it will try dispatching to an action with
the generated name, and failing that it will try to dispatch to a regular
method.

    sub foo :Local :Does('Methods') {
      ... do setup for HTTP method specific handlers ...
    }
 
    sub foo_GET {
      ... do something for GET requests ...
    }
 
    # alternatively use an Action
    sub foo_PUT : Action {
      ... do something for PUT requests ...
    }
 
For example, in the example above, calling GET on "/foo" would result in
the foo_GET method being dispatched.
 
If a method is requested that is not implemented, this action will
return a status 405 (Method Not Found).  It will populate the C<Allow> header
with the list of implemented request methods.  You can override this behavior
by implementing a custom 405 handler like so:
 
   sub foo_not_implemented {
      ... handle not implemented methods ...
   }
 
If you do not provide an _OPTIONS subroutine, we will automatically respond
with a 204 (No Content). The C<Allow> header will be populated with the list of
implemented request methods. If you do not provide an _HEAD either, we will
auto dispatch to the _GET one in case it exists.

=head1 VERSUS Catalyst::Action::REST

L<Catalyst::Action::REST> works fine doesn't it?  Why offer a new approach?  There's
a few reasons:

First, when L<Catalyst::Action::REST> was written we did not have
L<Moose> and the only way to augment functionality was via inheritance.  Now that
L<Moose> is common we instead say that it is typically better to use a L<Moose::Role>
to augment a class function rather to use a subclass.  The role approach is a smaller
hammer and it plays nicer when you need to combine several roles to augment a class
(as compared to multiple inheritance approaches.).  This is why we brought support for
action roles into core L<Catalyst::Controller> several years ago.  Letting you have
this functionality via a role should lead to more flexible systems that play nice
with other roles.  One nice side effect of this 'play nice with others' is that we
were able to hook into the 'list_extra_info' method of the core action class so that
you can now see in your developer mode debug output the matched http methods, for
example:

    .-------------------------------------+----------------------------------------.
    | Path Spec                           | Private                                |
    +-------------------------------------+----------------------------------------+
    | /myaction/*/next_action_in_chain    | GET, HEAD, POST /myaction (1)          |
    |                                     | => /next_action_in_chain (0)           |
    '-------------------------------------+----------------------------------------'

This is not to say its never correct to use an action class, but now you have the
choice.

Second, L<Catalyst::Action::REST> has the behavior as noted of altering the core
L<Catalyst::Request> class.  This might not be desired and has always struck the
author as a bit too much side effect / action at a distance.

Last, L<Catalyst::Action::REST> is actually a larger distribution with a bunch of
other features and dependencies that you might not want.  The intention is to offer
those bits of functionality as standalone, modern components and allow one to assemble
the parts needed, as needed.

This action role is for the most part a 1-1 port of the action class, with one minor
change to reduce the dependency count.  Additionally, it does not automatically
apply the L<Catalyst::Request::REST> action class to your global L<Catalyst>
action class. This feature is left off because its easy to set this yourself if
desired via the global L<Catalyst> configuration and we want to follow and promote
the idea of 'do one thing well and nothing surprising'.

B<NOTE> There is an additional minor change in how we handle return values from actions.  In
general L<Catalyst> does nothing with an action return value (unless in an auto action).
However this might not always be the future case, and you might have used that return value
for something in your custom code.  In L<Catalyst::Action::REST> the return value was
always the return of the dispatched sub action (if any).  We tweaked this so that we use
the sub action return value, BUT if that value is undefined, we use the parent action
return value instead.

We also dropped saying 'REST' when all we are doing is dispatching on HTTP method.
Since the time that the first version of L<Catalysts::Action::REST> was released to
CPAN our notion of what 'REST' means has greatly evolved so I think its correct to
change the name to be functionality specific and to not confuse people that are new
to the REST discipline.

This action role is intended to be used in all the places
you used to use the action class and have the same results, with the exception
of the already mentioned 'not messing with the global request class'.  However
L<Catalyst::Action::REST> has been around for a long time and is well vetted in
production so I would caution care with changing your mission critical systems
very quickly.

=head1 VERSUS NATIVE METHOD ATTRIBUTES

L<Catalyst> since version 5.90030 has offered a core approach to dispatch on the
http method (via L<Catalyst::ActionRole::HTTPMethods>).  Why still use this action role
versus the core functionality?  ALthough it partly comes down to preference and the
author's desire to give current users of L<Catalyst::Action::REST> a path forward, there
is some functionality differences beetween the two which may recommend one over the
other.  For example the core method matching does not offer an automatic default
'Not Implemented' response that correctly sets the OPTIONS header.  Also the dispatch
flow between the two approaches is different and when using chained actions one 
might be a better choice over the other depending on how your chains are arranged and
your desired flow of action.

=head1 METHODS
 
This role contains the following methods.

=head2 get_allowed_methods

Returns a list of the allowed methods.

=head2 dispatch
 
This method overrides the default dispatch mechanism to the re-dispatching
mechanism described above.

=head1 AUTHOR

  John Napiorkowski <jnapiork@cpan.org>

Author list from L<Catalyst::Action::REST>
 
  Adam Jacob E<lt>adam@stalecoffee.orgE<gt>, with lots of help from mst and jrockway
  Marchex, Inc. paid me while I developed this module. (L<http://www.marchex.com>)
 
=head1 CONTRIBUTORS

The following contributor list was copied from L<Catalyst::Action::REST>
from where the bulk of this code was copied.
 
Tomas Doran (t0m) E<lt>bobtfish@bobtfish.netE<gt>
 
John Goulah
 
Christopher Laco
 
Daisuke Maki E<lt>daisuke@endeworks.jpE<gt>
 
Hans Dieter Pearcey
 
Brian Phillips E<lt>bphillips@cpan.orgE<gt>
 
Dave Rolsky E<lt>autarch@urth.orgE<gt>
 
Luke Saunders
 
Arthur Axel "fREW" Schmidt E<lt>frioux@gmail.comE<gt>
 
J. Shirley E<lt>jshirley@gmail.comE<gt>
 
Gavin Henry E<lt>ghenry@surevoip.co.ukE<gt>
 
Gerv http://www.gerv.net/
 
Colin Newell <colin@opusvl.com>
 
Wallace Reis E<lt>wreis@cpan.orgE<gt>
 
André Walker (andrewalker) <andre@cpan.org>
 
=head1 COPYRIGHT
 
Copyright (c) 2006-2015 the above named AUTHOR and CONTRIBUTORS
 
=head1 LICENSE
 
You may distribute this code under the same terms as Perl itself.
 
=cut
