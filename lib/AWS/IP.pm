use strict;
use warnings;
package AWS::IP;
use Cache::File;
use Carp;
use HTTP::Tiny;
use JSON::XS;
use File::Temp 'tempdir';

# required by HTTP::Tiny for https
use IO::Socket::SSL 1.56;
use Net::SSLeay 1.49;

use constant CACHE_KEY => 'AWS_IPS';

# ABSTRACT: Get and search AWS IP ranges in a caching, auto-refreshing way

=head2 SYNOPSIS

  use AWS::IP;

  my $aws = AWS::IP->new(600, '/tmp/aws_ip_cache');
  my $aws_ip_data = $aws->get_raw_data;

  my $cidrs = $aws->get_cidrs;

  for (@$cidrs)
  {
    ...
  }

  my $ec2_cidrs = $aws->get_cidrs_by_service('EC2');

  # time passes, get updated ip list
  $aws_ip_data = $aws->get_raw_data;

  # or start a new program with the same cache_path

=head2 DESCRIPTION

AWS L<publish|https://ip-ranges.amazonaws.com/ip-ranges.json> their IP ranges, which periodically change. This module downloads and serializes the IP ranges into a Perl data hash reference. It caches the data, and if the cache expires, re-downloads a new version. This can be helpful if you want to block all AWS IP addresses and periodically refresh the blocked IPs.

=head2 new ($cache_timeout_secs, [$cache_path])

Creates a new AWS::IP object and sets up the cache. Requires an number for the cache timeout seconds. Optionally takes a cache path argument. If no cache path is supplied, AWS::IP will use a random temp directory. If you want to reuse the cache over multiple processes, provide a cache path.

=cut

sub new
{
  croak 'Incorrect number of args passed to AWS::IP->new()' unless @_ >= 2 && @_ <= 3;
  my ($class, $cache_timeout_secs, $cache_path) = @_;

  # validate args
  unless ($cache_timeout_secs
          && $cache_timeout_secs =~ /^[0-9]+$/)
  {
    croak 'Error argument cache_timeout_secs must be a positive integer';
  }

  bless {
          cache => Cache::File->new(  cache_root => ($cache_path || tempdir()),
                                      lock_level => Cache::File::LOCK_LOCAL(),
                                      default_expires => "$cache_timeout_secs sec"),
        }, $class;
}

=head2 get_raw_data

Returns the entire raw IP dataset as a Perl data structure.

=cut

sub get_raw_data
{
  my ($self) = @_;

  my $entry = $self->{cache}->entry(CACHE_KEY);

  if ($entry->exists)
  {
    decode_json($entry->get());
  }
  else
  {
    decode_json($self->_refresh_cache);
  }
}

=head2 get_cidrs

Returns an arrayref of the L<CIDRs|http://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing> in the AWS IP address data.

=cut

sub get_cidrs
{
  my ($self) = @_;
  [ map { $_->{ip_prefix} } @{$self->get_raw_data->{prefixes}} ];
}

=head2 get_cidrs_by_region ($region)

Returns an arrayref of CIDRs matching the provided region.

=cut

sub get_cidrs_by_region
{
  my ($self, $region) = @_;
  [ map { $_->{ip_prefix} } grep { $_->{region} eq $region } @{$self->get_raw_data->{prefixes}} ];
}

=head2 get_cidrs_by_service ($service)

Returns an arrayref of CIDRs matching the provided service.

=cut

sub get_cidrs_by_service
{
  my ($self, $service) = @_;
  [ map { $_->{ip_prefix} } grep { $_->{service} eq $service } @{$self->get_raw_data->{prefixes}} ];
}

=head2 get_regions

Returns an arrayref of the regions in the AWS IP address data.

=cut

sub get_regions
{
  my ($self) = @_;
  my %regions;
  for (@{$self->get_raw_data->{prefixes}})
  {
    $regions{ $_->{region} } = 1;
  }
  [ keys %regions ];
}

=head2 get_services

Returns an arrayref of the services (Amazon, EC2 etc) in the AWS IP address data.

=cut

sub get_services
{
  my ($self) = @_;
  my %services;
  for (@{$self->get_raw_data->{prefixes}})
  {
    $services{ $_->{service} } = 1;
  }
  [ keys %services ];
}

=head2 SEE ALSO

L<AWS::Networks> - is similar to this module but does not provide cacheing.

Amazon's L<page|http://docs.aws.amazon.com/general/latest/gr/aws-ip-ranges.html> on AWS IP ranges.

=cut


sub _refresh_cache
{
  my ($self) = @_;

  my $response = HTTP::Tiny->new->get('https://ip-ranges.amazonaws.com/ip-ranges.json');

  if ($response->{success})
  {
    my $entry = $self->{cache}->entry(CACHE_KEY);

    if ($entry->exists)
    {
      $entry->set($response->{content});
    }
    else
    {
        $self->{cache}->set(CACHE_KEY, $response->{content});
    }
    $response->{content};
  }
  else
  {
    croak "Error requesting $response->{url} $response->{code} $response->{reason}";
  }
}

1;
