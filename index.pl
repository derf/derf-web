#!/usr/bin/env perl

use strict;
use warnings;
use 5.014;
use utf8;

use Encode qw(decode);
use File::MimeInfo qw(mimetype);
use List::MoreUtils qw(firstidx);
use Mojolicious::Lite;
use Mojolicious::Static;
use Mojolicious::Types;
use File::Path qw(make_path);
use File::Slurp qw(read_dir read_file write_file);
use Image::Imlib2;

no if $] >= 5.018, warnings => "experimental::smartmatch";

our $VERSION = '0.00';
my $baseurl  = $ENV{BASEURL}      // 'https://fs.finalrewind.org';
my $prefix   = $ENV{EFS_PREFIX}   // '/home/derf/lib';
my $thumbdir = $ENV{EFS_THUMBDIR} // '/home/derf/var/local/efs-thumbs';
my $hwdb     = $ENV{HWDB_PATH}    // '/home/derf/packages/hardware/var/db';
my $listen   = $ENV{DWEB_LISTEN}  // 'http://*:8099';

my $type = Mojolicious::Types->new;

my %restrictions;
my ( @pgctl_auth, @pgctl_ro, @pgctl_rw );

#my @hwdb_export = qw(
#  RK SE SL SR S1 S5
#);

my $re_hwdb_desc = qr{
	^
	(?<location> \S+ )
	\s* := \s*
	(?<description> .+ )
	$
}x;
my $re_hwdb_item = qr{
	^
	(?<location> [^|]+? )
	\s* \| \s*
	(?<amount> [^|]+ )
	\s* \| \s*
	(?<description> [^|]+ )
	(
		\s* \| \s*
		(?<extra> [^|]+ )
		$
	)?
}x;

sub load_pgctl {
	if ( -e 'pgctl_auth' ) {
		@pgctl_auth = map { split } read_file('pgctl_auth');
	}
	if ( -e 'pgctl_ro' ) {
		@pgctl_ro = map { split } read_file('pgctl_ro');
	}
	if ( -e 'pgctl_rw' ) {
		@pgctl_rw = map { split } read_file('pgctl_rw');
	}
}

sub get_pgctl_env {
	my @pgctl_env;

	if ( not -e 'pgctl_env' ) {
		return;
	}

	for my $line ( read_file('pgctl_env', binmode => ':utf8') ) {
		my ( $label, $file, $unit, $type ) = split( qr{ \s+ }ox, $line );

		my $content = read_file($file);
		chomp $content;

		push( @pgctl_env, [ $label, $content, $unit, $type ] );
	}

	return @pgctl_env;
}

sub load_restrictions {
	if ( -e 'efs_auth' ) {
		open( my $fh, '<', 'efs_auth' ) or die("Can't open efs_auth: $!\n");
		while ( my $line = <$fh> ) {
			chomp $line;
			my ( $user, $dirs ) = split( /\s*:\s*/, $line );
			my @dirs = split( /\s+/, $dirs );
			$restrictions{$user} = \@dirs;
		}
		close($fh) or warn("Can't close efs_auth: $!\n");
	}
}

sub get_user {
	my ($self) = @_;

	my $authstr = $self->req->headers->authorization;
	my ($user) = ( $authstr =~ m{ Digest \s username = " ([^"]+) " }x );

	return $user // $authstr;
}

sub check_path_allowed {
	my ( $user, $path ) = @_;

	$path =~ s{ ^ [.] / }{}ox;

	if ( $path =~ m{ / [.] [.] $ }ox ) {
		return 1;
	}

	if ( not $user or not length($user) ) {
		return 0;
	}

	if ( not exists $restrictions{$user} ) {
		return 1;
	}
	if ( not $path or length($path) <= 1 ) {
		return 1;
	}
	for my $prefix ( @{ $restrictions{$user} } ) {
		if (   ( substr( $path, 0, length($prefix) ) eq $prefix )
			or ( substr( $prefix, 0, length($path) ) eq $path ) )
		{
			return 1;
		}
	}

	return 0;
}

sub pgctl_get_status {
	my ($device) = @_;

	if ( $device ~~ \@pgctl_ro or $device ~~ \@pgctl_rw ) {
		my $status = qx{$device};
		chomp $status;
		return $status ? 1 : 0;
	}
	return 0;
}

sub pgctl_set_status {
	my ( $device, $status ) = @_;

	if ( $device ~~ \@pgctl_rw ) {
		my $arg = $status ? 'on' : 'off';
		system( $device, $arg );
	}
	return;
}

sub efs_list_file {
	my ( $path, $file, $params ) = @_;
	my $realpath = "${prefix}/${path}/${file}";
	my $url;

	if ( -l $realpath ) {
		$realpath = "${prefix}/${path}/" . readlink($realpath);
	}

	if ( mimetype($realpath) =~ m{ ^ image }ox ) {
		$url = "/efs/${path}/${file}.html?${params}";
	}
	elsif ( -d $realpath ) {
		$url = "/efs/${path}/${file}/?${params}";
	}
	else {
		$url = "/efs/${path}/${file}";
	}

	return [ $file, $url, "/efs/${path}/${file}" ];
}

sub sort_filenames {
	my ( $mode, $prefix, @files ) = @_;
	my @ret;

	if ( $mode eq 'mtime' ) {
		@ret = map { $_->[0] }
		  sort { $a->[1] <=> $b->[1] }
		  map { [ $_, +( stat "${prefix}/$_" )[9] ] } @files;
	}
	else {
		@ret = sort @files;
	}

	return @ret;
}

sub get_hwdb {
	my ($self) = @_;
	my $db;
	my %descs;

	my $lineno = 0;

	open( my $fh, '<', $hwdb );
	while ( my $line = <$fh> ) {
		chomp($line);

		if ( $line =~ $re_hwdb_desc ) {
			$descs{ $+{location} } = $+{description};
		}
		elsif ( $line =~ $re_hwdb_item ) {
			my $part = {
				location    => $+{location},
				locationv   => $descs{ $+{location} },
				line        => $lineno,
				amount      => $+{amount},
				description => decode( 'utf-8', $+{description} ),
			};
			if ( $+{extra} ) {
				my ( $shop, $artnr ) = split( /:/, $+{extra} );
				$part->{$shop} = $artnr;
			}
			push( @{$db}, $part );
		}
		$lineno++;
	}

	return $db;
}

sub update_hwdb {
	my %opt = @_;

	my @lines = read_file($hwdb);

	if ( defined $opt{amount} ) {
		my $amount = sprintf( '%4d', $opt{amount} );
		$lines[ $opt{line} ] =~ s/ ^ ( [^|]+ \s* \| ) \s* \d+ /${1}${amount}/x;
	}

	write_file( $hwdb, @lines );

	return;
}

sub serve_efs {
	my $self = shift;
	my $path = $self->stash('path') || q{.};
	my $sort = $self->param('sort') || 'name';

	my $param_s = $self->req->params->to_string;

	my $user = get_user($self);

	my ( $dir, $file ) = ( $path =~ m{ ^ (.+) / ([^/]+) \. html $ }ox );

	if ( not check_path_allowed( $user, $path ) ) {
		$self->redirect_to("${baseurl}/efs");
		return;
	}

	if ( $path =~ m{ \. html $ }ox ) {

		my @all_files = read_dir("${prefix}/${dir}");
		@all_files = grep { -f "${prefix}/${dir}/$_" } @all_files;

		@all_files = sort_filenames( $sort, "${prefix}/${dir}", @all_files );

		my $idx = firstidx { $_ eq $file } @all_files;

		my $prev_idx = ( $idx == 0           ? 0    : $idx - 1 );
		my $next_idx = ( $idx == $#all_files ? $idx : $idx + 1 );

		$self->render(
			'efs-main',
			prev       => $all_files[$prev_idx],
			next       => $all_files[$next_idx],
			randomlink => $all_files[ int( rand($#all_files) ) ],
			prevlink   => $all_files[$prev_idx] . ".html?${param_s}",
			nextlink   => $all_files[$next_idx] . ".html?${param_s}",
			randomlink => $all_files[ int( rand($#all_files) ) ]
			  . ".html?${param_s}",
			parentlink => $dir,
			file       => $file,
		);
	}
	elsif ( -d "${prefix}/${path}" ) {
		$path =~ s{ / $ }{}ox;
		my @all_files = read_dir( "${prefix}/${path}", keep_dot_dot => 1 );
		@all_files
		  = grep { check_path_allowed( $user, "${path}/$_" ) } @all_files;
		@all_files = sort_filenames( $sort, "${prefix}/${path}", @all_files );
		@all_files = map { efs_list_file( $path, $_, $param_s ) } @all_files;
		$self->render( 'efs-list', files => \@all_files, );
	}
	else {
		if ( $self->param('thumb') ) {

			my $thumb_path = $path;
			$thumb_path =~ s{ \. gif $ }{.png}ox;

			if ( not -e "${thumbdir}/thumbs/${path}" ) {
				my $im        = Image::Imlib2->load("${prefix}/${path}");
				my $thumb     = $im;
				my $thumb_dim = 250;
				my ( $dx, $dy ) = ( $im->width, $im->height );

				my ( $dpath, $file ) = ( $path =~ m{ (.+) / ([^/])+ $ }ox );

				make_path("${thumbdir}/thumbs/${dpath}");

				if ( $dx > $thumb_dim or $dy > $thumb_dim ) {
					if ( $dx > $dy ) {
						$thumb = $im->create_scaled_image( $thumb_dim, 0 );
					}
					else {
						$thumb = $im->create_scaled_image( 0, $thumb_dim );
					}
				}
				$thumb->set_quality(75);
				$thumb->save("${thumbdir}/thumbs/${thumb_path}");
			}
			$path = "thumbs/${thumb_path}";
		}
		my $fn = ( split( qr{/},   $path ) )[-1];
		my $ft = ( split( qr{[.]}, $fn ) )[-1];
		my $ct = $type->type($ft);
		$self->res->headers->content_disposition("inline; filename=${fn}");
		$self->res->headers->content_type("$ct; name=${fn}");
		$self->render_static($path);
	}

}

sub serve_hwdb {
	my ($self) = @_;
	my $lineno = $self->param('line');
	my $amount = $self->param('amount');

	if ( $lineno and defined $amount ) {
		update_hwdb(
			line   => $lineno,
			amount => $amount
		);
		$self->redirect_to("${baseurl}/hwdb");
		return;
	}

	my $db = get_hwdb;

	$self->render( 'hwdb-list', db => $db );

}

sub serve_pgctl {
	my ($self) = @_;

	my %devices;
	my @envlist = get_pgctl_env();

	for my $device (@pgctl_ro) {
		$devices{$device} = {
			status => pgctl_get_status($device) ? 'on' : 'off',
			access => 'ro',
		};
	}
	for my $device (@pgctl_rw) {
		$devices{$device} = {
			status => pgctl_get_status($device) ? 'on' : 'off',
			access => 'rw',
		};
	}

	my $user = get_user($self);

	if ( $user ~~ \@pgctl_auth ) {
		$self->render(
			'pgctl',
			devices => \%devices,
			envlist => \@envlist
		);
	}
	else {
		$self->render(
			'pgctl',
			devices => [],
			envlist => \@envlist
		);
	}

	return;
}

sub serve_pgctl_toggle {
	my ($self) = @_;
	my $device = $self->stash('device');

	my $user = get_user($self);

	if ( $user ~~ [qw[derf feuerrot]] ) {
		pgctl_set_status( $device, !pgctl_get_status($device) );
	}

	$self->redirect_to("${baseurl}/pgctl");
	return;
}

load_pgctl();
load_restrictions();

get '/efs/'                 => \&serve_efs;
get '/efs/*path'            => \&serve_efs;
get '/hwdb/'                => \&serve_hwdb;
get '/pgctl'                => \&serve_pgctl;
get '/pgctl/toggle/:device' => \&serve_pgctl_toggle;

app->config(
	hypnotoad => {
		listen   => [$listen],
		pid_file => '/tmp/derf_web.pid',
		workers  => 2,
	},
);

app->defaults( layout => 'default' );
push( @{ app->static->paths }, $prefix );
push( @{ app->static->paths }, $thumbdir );

app->start;
