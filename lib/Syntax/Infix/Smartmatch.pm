package Syntax::Infix::Smartmatch;

use strict;
use warnings;

use XSLoader;

XSLoader::load(__PACKAGE__, __PACKAGE__->VERSION);

my $warning = $] >= 5.038 ? 'deprecated::smartmatch' : $] >= 5.018 ? 'experimental::smartmatch' : undef;

sub import {
	$^H |= 0x020000;
	$^H{"Syntax::Infix::Smartmatch/enabled"} = 1;
	warnings->unimport($warning) if defined $warning;
}

sub unimport {
	$^H |= 0x020000;
	delete $^H{"Syntax::Infix::Smartmatch/enabled"};
}

1;

# ABSTRACT: Smartmatch done right

=head1 SYNOPSIS

 say "YES" if $value ~~ [1, 2, qr/42/];

=head1 DESCRIPTION

B<NOTE: This module is currently still experimental and the details of its behavior may still change>.

This module implements a new, much simplified version of smartmatch. In particular the behavior only depends on the right side argument. In particular it will do the following based on the right side argument:

=over 4

=item * undef

This will return C<not defined $left>.

=item * object

If the object has smartmatch overloading (note: this might disappear in a future Perl version), that is called. Otherwise it returns object identity.

=item * regex

This is equivalent to C<$left =~ $right>.

=item * sub

It will return the value of C<< $right->($left) >>

=item * array

This will compare every element of C<@$left> to see if it smartmatches every element of C<@$right>. E.g. C<< $left->[0] ~~ $right->[0] && $left->[1] ~~ $right->[1] && ... >>

=item * other

This will return C<$left equ $right> (C<defined $left and $left eq $right>).

=back
