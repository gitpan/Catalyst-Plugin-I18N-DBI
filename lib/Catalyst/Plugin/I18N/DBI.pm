package Catalyst::Plugin::I18N::DBI;

use strict;
use warnings;

use base qw(Locale::Maketext);

use DBI;
use NEXT;
use I18N::LangTags ();
use I18N::LangTags::Detect;

use Locale::Maketext::Lexicon;

use version; our $VERSION = qv("0.1.0");

=head1 NAME

Catalyst::Plugin::I18N::DBI - DBI based I18N for Catalyst

=head1 SYNOPSIS

    use Catalyst 'I18N::DBI';

    print $c->loc('Hello Catalyst');

Or in your Mason code:

   <% $c->loc('Hello [_1]', 'Catalyst') %>

Or in your TT code (with macro): 

   [% MACRO l(text, args) BLOCK;
       c.loc(text, args);
   END; %]

   [% l('Hello Catalyst') %]
   [% l('Hello [_1]', 'Catalyst') %]
   [% l('lalala[_1]lalala[_2]', ['test', 'foo']) %]

=head1 DESCRIPTION

Unlike L<Catalyst::Plugin::I18N::DBIC> this plugin isn't based on any other Catalyst plugin.
It makes direct use of L<Locale::Maketext::Lexicon> and L<Locale::Maketext::Lexicon::DBI>.

Lexicon texts are held in a database table where you can have several lexicons
which are separated by the 'lex' column.  See L<Locale::Maketext::Lexicon::DBI> for more
information about the table definition.  All specified lexicons are loaded into memory
at startup, so we don't need to fetch the lexicon entries every time we need them.

Please read this document and L<Catalyst::Plugin::I18N::DBIC>'s POD carefully before
deciding which module to use in your case.

=head2 CONFIGURATION

In order to be able to connect to the database, this plugin needs some configuration,
for example:

    __PACKAGE__->config(
        'I18N::DBI' => {
                         dsn       => 'dbi:Pg:dbname=postgres',
                         user      => 'pgsql',
                         password  => '',
                         languages => [qw(de en)],
                         lexicons  => [qw(*)],
                       },
    );

=over

=item dsn

This is the Data Source Name which will be passed to the C<connect> method of L<DBI>.
See L<DBI> for more information about DSN syntax.

=item user

Name of a database user with read B<and> write access to the lexicon table
and dependent sequences.  (When C<fail_with> is set to C<0>, the user doesn't
need to have write access.)

=item password

The password for the database user.

=item languages

An array reference with language names that shall be loaded into memory.  Basically,
this is the content of the C<lang> column.

=item fail_with

Boolean indicating whether to use the C<fail_with> function or not.  Defaults to true.
See L</FAQ> for details.

=back

=head2 METHODS

=head3 loc

Localize text:

    print $c->loc('Welcome to Catalyst, [_1]', 'Matt');

=cut

sub loc {
    my ($self, $text, $args) = @_;

    my @user_lang = I18N::LangTags::implicate_supers(
                        I18N::LangTags::Detect->http_accept_langs($self->request->header('Accept-Language')));
    my $handles = $self->config->{'I18N::DBI'}->{handles};

    my $lang_handle;
    foreach (@user_lang) {
        if ($lang_handle = $handles->{$_}) {
            last;
        }
    }

    unless ($lang_handle) {
        unless ($lang_handle = $handles->{ $self->config->{'I18N::DBI'}->{default_lang} }) {
            $self->log->fatal(
                    "No default language '" . $self->config->{'I18N::DBI'}->{default_lang} . "' available!");
            return $text;
        }
    }

    if (ref $args eq 'ARRAY') {
        return $lang_handle->maketext($text, @$args);
    } else {
        return $lang_handle->maketext($text, $args, @_);
    }
}

=head2 EXTENDED AND INTERNAL METHODS

Not described here.

=cut

sub setup {
    my $c = shift;

    $c->_init_i18n;
    $c->log->debug("I18N Initialized");

    $c->NEXT::setup(@_);
}

sub _init_i18n {
    my $self = shift;

    my $cfg = $self->config->{'I18N::DBI'};
    my $dbh = DBI->connect($cfg->{dsn}, $cfg->{user}, $cfg->{password}, $cfg->{attr});

    my $default_lex = $cfg->{lexicons}->[0];

    my %handles;
    foreach my $lang (@{ $cfg->{languages} }) {
        $lang =~ y/_/-/;

        foreach my $lex (@{ $cfg->{lexicons} }) {

            eval <<"";
                package ${self}::${lang};
                no strict;
                use base 'Locale::Maketext';
                # Need a dummy key to overlive the optimizer (or similar)!
                %Lexicon = (dummy => '1');

            eval <<"";
                package $self;
                use base 'Locale::Maketext';
                Locale::Maketext::Lexicon->import(
                                       { \$lang => ['DBI' => ['lang' => \$lang, 'lex' => \$lex, dbh => \$dbh]] });

            if ($@) {
                $self->log->error(qq|Couldn't initialize I18N for lexicon $lang/$lex, "$@"|);
            } else {
                $self->log->debug(qq|Lexicon $lang/$lex loaded|);
            }
        }

        $handles{$lang} = $self->get_handle($lang);

        if (!defined $cfg->{fail_with} || $cfg->{fail_with}) {
            $handles{$lang}->fail_with(
                sub {
                    my ($flh, $key, @params) = @_;
                    eval {
                        my $res = $self->model('Lexicon')->search({ key => $key, lang => $lang, lex => $default_lex })->first;
                        unless ($res) {
                            my $rec = $self->model('Lexicon')->create(
                                                                      {
                                                                        lex   => $default_lex,
                                                                        key   => $key,
                                                                        value => '? ' . $key,
                                                                        lang  => $lang
                                                                      }
                                                                     );
                        }
                    };
                    $self->log->error("Failed within fail_with(): $@") if $@;
    
                    return $key;
                }
            );
        }
    }

    $cfg->{handles} = \%handles;

    $dbh->disconnect;
}

=head1 FAQ

=head2 Why use C<C::P::I18N::DBI> instead of C<C::P::I18N::DBIC>?

Sometimes you don't want to select and parse the data from the database each
time you access your lexicon.  Then C<C::P::I18N::DBI> is for you!  It loads the
lexicon into memory at startup instead of fetching it over and over again.
But be careful, as this approach can waste a lot of memory and may slow your
system down (depending of the amount of data in your lexicon).

I recommend to test both modules and decide which one is more suitable
depending on your production environment.

=head2 Why does the database user needs write access?  Or: What's the C<fail_with> function? 

C<C::P::I18N::DBI> implements a C<fail_with> method that attempts to create a new
database entry whenever a lexicon lookup fails.  The value is set to the lexicon
key prefixed with the string C<? >.

Example: you look up C<FooBar>, which doesn't exist.  A new database entry will be
created with that key, the value will be C<? FooBar>.

You can disable this behavior by setting the config key C<fail_with> to zero.

=head1 SEE ALSO

L<Calatyst>, L<Locale::Maketext>, L<Locale::Maketext::Lexicon>, L<Locale::Maketext::Lexicon::DBI>, L<DBI>,
L<Catalyst::Plugin::I18N::DBIC>

=head1 AUTHOR

Matthias Dietrich, C<< <perl@rainboxx.de> >>

=head1 COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
