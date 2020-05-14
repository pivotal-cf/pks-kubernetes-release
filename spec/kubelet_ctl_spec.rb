# frozen_string_literal: true

require 'rspec'
require 'spec_helper'
require 'fileutils'
require 'open3'

def call_function(rendered_kubelet_ctl, executable_path, function_name)
  File.open(executable_path, 'w', 0o777) do |f|
    f.write(rendered_kubelet_ctl)
  end

  # exercise bash function by changing path for any necessary executables to our mocks in /tmp/mock/*
  cmd = format('PATH=%<dirname>s:%<env_path>s /bin/bash -c "source %<exe>s && %<func_name>s"',
               dirname: File.dirname(executable_path), env_path: ENV['PATH'], exe: executable_path, func_name: function_name)

  # capturing stderr (ignored) prevents expected warnings from showing up in test console
  result, = Open3.capture3(cmd)
  result
end

describe 'kubelet_ctl' do
  let(:link_spec) do {
    'kube-apiserver' => {
      'instances' => [],
      'properties' => {
        'tls-cipher-suites' => 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'
      }
    },
    'etcd' => {
      'properties' => { },
      'instances' => [ ]
    }
  }
  end

  let(:rendered_template) do
    compiled_template('kubelet', 'bin/kubelet_ctl', {}, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
  end

  it 'includes default tls-cipher-suites' do
    expect(rendered_template).to include('--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384')
  end

  it 'labels the kubelet with its own az' do
    expect(rendered_template).to include(',bosh.zone=z1')
  end

  it 'labels the kubelet with the spec ip' do
    expect(rendered_template).to include('spec.ip=fake-bosh-ip')
  end

  it 'labels the kubelet with the bosh id' do
    expect(rendered_template).to include(',bosh.id=fake-bosh-id')
  end

  describe 'kubelet labels and taints' do
    let(:test_context) do
      mock_dir = '/tmp/kubelet_mock'
      FileUtils.remove_dir(mock_dir, true)
      FileUtils.mkdir(mock_dir)
      kubelet_ctl_file = mock_dir + '/kubelet_ctl'

      { 'mock_dir' => mock_dir, 'kubelet_ctl_file' => kubelet_ctl_file }
    end
    after(:each) do
      FileUtils.remove_dir(test_context['mock_dir'], true)
    end

    describe 'without input from k8s-args' do
      it 'should add default label' do
        manifest_properties = {
          'k8s-args' => {
          }
        }
        rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
        labels = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_labels")
        taints = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_taints")

        expect(labels).to include('bosh.zone=z1')
        expect(labels).to include('spec.ip=fake-bosh-ip')
        expect(labels).to include('bosh.id=fake-bosh-id')
      end
    end

    describe 'with custom labels passed to k8s-args' do
      it 'should add custom label' do
        manifest_properties = {
          'k8s-args' => {
            'node-labels' => 'foo=bar,k8s.node=custom'
          }
        }
        rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
        labels = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_labels")

        expect(labels).to include('bosh.zone=z1')
        expect(labels).to include('spec.ip=fake-bosh-ip')
        expect(labels).to include('bosh.id=fake-bosh-id')
        expect(labels).to include('k8s.node=custom')
        expect(labels).to include('foo=bar')
      end
    end

    describe 'with custom taints passed to k8s-args' do
      it 'should add custom taints' do
        manifest_properties = {
          'k8s-args' => {
            'register-with-taints' => 'foo=bar:NoExecute,k8s.node=custom:NoExecute'
          }
        }
        rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
        taints = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_taints")

        expect(taints).to include('foo=bar:NoExecute')
        expect(taints).to include('k8s.node=custom:NoExecute')
      end
    end

    describe 'with custom labels and taints passed to k8s-args' do
      it 'should add custom taints' do
        manifest_properties = {
          'k8s-args' => {
            'node-labels' => 'foo=bar,k8s.node=custom',
            'register-with-taints' => 'foo=bar:NoExecute,k8s.node=custom:NoExecute'
          }
        }
        rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
        labels = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_labels")
        taints = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_taints")

        expect(labels).to include('bosh.zone=z1')
        expect(labels).to include('spec.ip=fake-bosh-ip')
        expect(labels).to include('bosh.id=fake-bosh-id')
        expect(labels).to include('k8s.node=custom')
        expect(labels).to include('foo=bar')

        expect(taints).to include('foo=bar:NoExecute')
        expect(taints).to include('k8s.node=custom:NoExecute')
      end
    end

    describe 'with custom labels and taints read from custom-label-taint folder' do
      let(:custom_file_context) do
        folder = "/var/vcap/store/custom-label-taint"
        label_file = folder + "/labels"
        taint_file = folder + "/taints"

        FileUtils.mkdir_p(folder)
        File.open(label_file, 'w', 0o600)
        File.open(taint_file, 'w', 0o600)
        {
          'label_file' => label_file,
          'taint_file' => taint_file,
          'folder' => folder
        }
      end
      after(:each) do
        FileUtils.remove_dir(custom_file_context['folder'], true)
      end

      describe 'label_file has content' do
        it 'should add custom labels' do
          File.open(custom_file_context['label_file'], 'w', 0o600) do |f|
            f.write("l1=l1\nl2=l2\n")
          end
          manifest_properties = {'k8s-args' => {}}
          rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
          labels = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_labels")

          expect(labels).to include('bosh.zone=z1')
          expect(labels).to include('spec.ip=fake-bosh-ip')
          expect(labels).to include('bosh.id=fake-bosh-id')
          expect(labels).to include('l1=l1')
          expect(labels).to include('l2=l2')
        end
      end

      describe 'taint_file has content' do
        it 'should add custom taints' do
          File.open(custom_file_context['taint_file'], 'w', 0o600) do |f|
            f.write("t1=t1:NoExecute\nt2=t2:Execute\n")
          end
          manifest_properties = {'k8s-args' => {}}
          rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
          taints = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_taints")

          expect(taints).to include('t1=t1:NoExecute')
          expect(taints).to include('t2=t2:Execute')
        end
      end

      describe 'label_file and taint_file has content' do
        it 'should add custom labels and taints' do
          File.open(custom_file_context['label_file'], 'w', 0o600) do |f|
            f.write("l1=l1\nl2=l2\n")
          end
          File.open(custom_file_context['taint_file'], 'w', 0o600) do |f|
            f.write("t1=t1:NoExecute\nt2=t2:Execute\n")
          end
          manifest_properties = {'k8s-args' => {}}
          rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
          labels = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_labels")
          taints = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_taints")

          expect(labels).to include('l1=l1')
          expect(labels).to include('l2=l2')

          expect(taints).to include('t1=t1:NoExecute')
          expect(taints).to include('t2=t2:Execute')
        end
      end

      describe 'label_file and taint_file has content, labels and taints are passed through k8s-args' do
        it 'should add custom labels and taints' do
          File.open(custom_file_context['label_file'], 'w', 0o600) do |f|
            f.write("l1=l1\nl2=l2\n")
          end
          File.open(custom_file_context['taint_file'], 'w', 0o600) do |f|
            f.write("t1=t1:NoExecute\nt2=t2:Execute\n")
          end
          manifest_properties = {
            'k8s-args' => {
              'node-labels' => 'foo=bar,k8s.node=custom',
              'register-with-taints' => 'foo=bar:NoExecute,k8s.node=custom:NoExecute'
            }
          }
          rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1', 'fake-bosh-ip', 'fake-bosh-id')
          labels = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_labels")
          taints = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], "construct_taints")

          expect(labels).to include('bosh.zone=z1')
          expect(labels).to include('spec.ip=fake-bosh-ip')
          expect(labels).to include('bosh.id=fake-bosh-id')
          expect(labels).to include('k8s.node=custom')
          expect(labels).to include('foo=bar')
          expect(labels).to include('l1=l1')
          expect(labels).to include('l2=l2')

          expect(taints).to include('foo=bar:NoExecute')
          expect(taints).to include('k8s.node=custom:NoExecute')
          expect(taints).to include('t1=t1:NoExecute')
          expect(taints).to include('t2=t2:Execute')
        end
      end
    end
  end

  it 'has no http proxy when no proxy is defined' do
    rendered_kubelet_ctl = compiled_template(
      'kubelet',
      'bin/kubelet_ctl',
      {},
      link_spec
    )

    expect(rendered_kubelet_ctl).not_to include('export http_proxy')
    expect(rendered_kubelet_ctl).not_to include('export https_proxy')
    expect(rendered_kubelet_ctl).not_to include('export no_proxy')
  end

  it 'sets http_proxy when an http proxy is defined' do
    rendered_kubelet_ctl = compiled_template(
      'kubelet',
      'bin/kubelet_ctl',
      { 'http_proxy' => 'proxy.example.com:8090' },
      link_spec
    )

    expect(rendered_kubelet_ctl).to include('export http_proxy=proxy.example.com:8090')
  end

  it 'sets https_proxy when an https proxy is defined' do
    rendered_kubelet_ctl = compiled_template(
      'kubelet',
      'bin/kubelet_ctl',
      { 'https_proxy' => 'proxy.example.com:8100' },
      link_spec
    )

    expect(rendered_kubelet_ctl).to include('export https_proxy=proxy.example.com:8100')
  end

  it 'sets no_proxy when no proxy property is set' do
    rendered_kubelet_ctl = compiled_template(
      'kubelet',
      'bin/kubelet_ctl',
      { 'no_proxy' => 'noproxy.example.com,noproxy.example.net' },
      link_spec
    )

    expect(rendered_kubelet_ctl).to include('export no_proxy=noproxy.example.com,noproxy.example.net')
    expect(rendered_kubelet_ctl).to include('export NO_PROXY=noproxy.example.com,noproxy.example.net')
  end

  context 'when cloud provider is azure' do
    it 'avoids setting bosh.zone to an (illegal) value "Availability Sets" that is set by OpsMan 2.5+' do
      manifest_properties = {
          'cloud-provider' => 'azure'
      }

      rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, az="Availability Sets")
      expect(rendered_kubelet_ctl).to include('cloud_provider="azure"')
      expect(rendered_kubelet_ctl).not_to include('bosh.zone=Availability Sets')
    end
  end

  describe 'setting of --hostname-override property' do
    let(:test_context) do
      mock_dir = '/tmp/kubelet_mock'
      FileUtils.remove_dir(mock_dir, true)
      FileUtils.mkdir(mock_dir)
      kubelet_ctl_file = mock_dir + '/kubelet_ctl'

      { 'mock_dir' => mock_dir, 'kubelet_ctl_file' => kubelet_ctl_file }
    end
    after(:each) do
      FileUtils.remove_dir(test_context['mock_dir'], true)
    end

    describe 'when cloud-provider is NOT gce' do
      it 'sets hostname_override to IP address of container IP' do
        expected_spec_ip = '1111'
        rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', { 'cloud-provider' => 'nonsense' }, link_spec, {}, 'az1', expected_spec_ip)
        result = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], 'get_hostname_override')

        expect(result).to include(expected_spec_ip)
      end
    end

    describe 'when cloud-provider is gce' do
      it 'sets hostname_override to gcp cloud id' do
        expected_google_hostname = 'i_am_groot'

        # mock out curl because this code path will try to use it.
        echo_mock_file = test_context['mock_dir'] + '/curl'
        File.open(echo_mock_file, 'w', 0o777) do |f|
          f.write("#!/bin/bash\n")
          f.write("echo #{expected_google_hostname}")
        end

        manifest_properties = {
          'cloud-provider' => 'gce'
        }

        test_link = {
          'cloud-provider' => {
            'instances' => [],
            'properties' => {
              'cloud-provider' => {
                'type' => 'gce',
                'gce' => {
                  'project-id' => 'f',
                  'network-name' => 'ff',
                  'worker-node-tag' => 'fff',
                  'service_key' => 'ffff'
                }
              }
            }
          },
          'kube-apiserver' => {
            'instances' => [],
            'properties' => {
              'tls-cipher-suites' => 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'
            }
          },
          'etcd' => {
            'properties' => { },
            'instances' => [ ]
          }
        }
        rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, test_link)
        expect(rendered_kubelet_ctl).to include('cloud_provider="gce"')

        result = call_function(rendered_kubelet_ctl, test_context['kubelet_ctl_file'], 'get_hostname_override')
        expect(result).to include(expected_google_hostname)
      end
    end
  end

  context 'when cloud provider is vsphere' do
    it 'does not set cloud-config' do
      manifest_properties = {
        'cloud-provider' => 'vsphere'
      }

      test_link = {
        'cloud-provider' => {
          'instances' => [],
          'properties' => {
            'cloud-provider' => {
              'type' => 'vsphere',
              'vsphere' => {
                'user' => 'fake-user',
                'password' => 'fake-password',
                'server' => 'fake-server',
                'port' => 'fake-port',
                'insecure-flag' => 'fake-insecure-flag',
                'datacenter' => 'fake-datacenter',
                'datastore' => 'fake-datastore',
                'working-dir' => 'fake-working-dir',
                'vm-uuid' => 'fake-vm-uuid',
                'scsicontrollertype' => 'fake-scsicontrollertype'
              }
            }
          }
        },
        'kube-apiserver' => {
          'instances' => [],
          'properties' => {
            'tls-cipher-suites' => 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'
          }
        },
        'etcd' => {
          'properties' => { },
          'instances' => [ ]
        }
      }
      rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, test_link)
      expect(rendered_kubelet_ctl).not_to include('--cloud-config')
      expect(rendered_kubelet_ctl).to include('cloud_provider="vsphere"')
    end

    it 'labels the kubelet with its own failure-domain' do
      manifest_properties = {
        'cloud-provider' => 'vsphere'
      }
      rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', manifest_properties, link_spec, {}, 'z1')
      expect(rendered_kubelet_ctl).to include(',failure-domain.beta.kubernetes.io/zone=z1')
    end
  end

  context 'when there is no cloud-provider link' do
    it 'does not set cloud options' do
      rendered_kubelet_ctl = compiled_template('kubelet', 'bin/kubelet_ctl', {}, link_spec)
      expect(rendered_kubelet_ctl).not_to include('--cloud-config')
      expect(rendered_kubelet_ctl).not_to include('--cloud-provider')
    end
  end
end
