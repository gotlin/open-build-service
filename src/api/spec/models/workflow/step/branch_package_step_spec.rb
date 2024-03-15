RSpec.describe Workflow::Step::BranchPackageStep, :vcr do
  let!(:user) { create(:confirmed_user, :with_home, login: 'Iggy') }
  let(:token) { create(:workflow_token, executor: user) }
  let(:target_project_name) { "home:#{user.login}" }
  let(:long_commit_sha) { '123456789' }
  let(:short_commit_sha) { '1234567' }

  subject do
    described_class.new(step_instructions: step_instructions,
                        scm_webhook: scm_webhook,
                        token: token)
  end

  RSpec.shared_context 'successful new PR or MR event' do
    before do
      create(:repository, name: 'Unicorn_123', project: package.project, architectures: %w[x86_64 i586 ppc aarch64])
      create(:repository, name: 'openSUSE_Tumbleweed', project: package.project, architectures: ['x86_64'])
    end

    let(:step_instructions) do
      {
        source_project: package.project.name,
        source_package: package.name,
        target_project: target_project_name
      }
    end

    it { expect { subject.call }.to(change(Package, :count).by(1)) }
    it { expect { subject.call.source_file('_branch_request') }.not_to raise_error }
    it { expect(subject.call.source_file('_branch_request')).to include('123') }
    it { expect { subject.call }.to(change(EventSubscription.where(eventtype: 'Event::BuildFail'), :count).by(1)) }
    it { expect { subject.call }.to(change(EventSubscription.where(eventtype: 'Event::BuildSuccess'), :count).by(1)) }
  end

  describe '#call' do
    let(:project) { create(:project, name: 'foo_project', maintainer: user) }
    let(:package) { create(:package_with_file, name: 'bar_package', project: project) }
    let(:final_package_name) { package.name }
    let(:scm_webhook) do
      SCMWebhook.new(payload: {
                       scm: 'github',
                       event: 'pull_request',
                       action: action,
                       pr_number: 1,
                       source_repository_full_name: 'reponame',
                       commit_sha: long_commit_sha,
                       target_repository_full_name: 'openSUSE/open-build-service'
                     })
    end

    before do
      project
      package
      login(user)
    end

    context 'for a new PR event' do
      let(:action) { 'opened' }
      let(:octokit_client) { instance_double(Octokit::Client) }

      before do
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive(:create_status).and_return(true)
      end

      it_behaves_like 'successful new PR or MR event'
    end

    context 'for a new_commit SCM webhook event' do
      context 'without branch permissions' do
        let(:action) { 'opened' }
        let(:octokit_client) { instance_double(Octokit::Client) }
        let(:branch_package_mock) { instance_double(BranchPackage) }
        let(:step_instructions) do
          {
            source_project: project.name,
            source_package: package.name,
            target_project: target_project_name
          }
        end

        before do
          allow(BranchPackage).to receive(:new).and_return(branch_package_mock)
          allow(branch_package_mock).to receive(:branch).and_raise(CreateProjectNoPermission)
        end

        it { expect { subject.call }.to raise_error(BranchPackage::Errors::CanNotBranchPackageNoPermission) }
      end

      context 'when the target package already exists' do
        let(:action) { 'synchronize' }
        let(:creation_payload) do
          { 'action' => 'opened', 'commit_sha' => long_commit_sha, 'event' => 'pull_request', 'pr_number' => 1, 'scm' => 'github', 'source_repository_full_name' => 'reponame',
            'target_repository_full_name' => 'openSUSE/open-build-service' }
        end
        let(:update_payload) do
          { 'action' => 'synchronize', 'commit_sha' => long_commit_sha, 'event' => 'pull_request', 'pr_number' => 1,
            'scm' => 'github', 'source_repository_full_name' => 'reponame',
            'target_repository_full_name' => 'openSUSE/open-build-service' }
        end
        let(:existing_branch_request_file) do
          {
            action: 'synchronize',
            pull_request: {
              head: {
                repo: { full_name: 'source_repository_full_name' },
                sha: '123'
              }
            }
          }.to_json
        end
        let(:step_instructions) do
          {
            source_project: package.project.name,
            source_package: package.name,
            target_project: target_project_name
          }
        end

        # Emulate the branched project/package and the subcription created in a previous new PR/MR event
        let!(:branched_project) { create(:project, name: "home:#{user.login}:openSUSE:open-build-service:PR-1", maintainer: user) }
        let!(:branched_package) { create(:package_with_file, name: package.name, project: branched_project) }

        ['Event::BuildFail', 'Event::BuildSuccess'].each do |build_event|
          let!("event_subscription_#{build_event.parameterize}") do
            EventSubscription.create(eventtype: build_event,
                                    receiver_role: 'reader',
                                    user: user,
                                    channel: :scm,
                                    enabled: true,
                                    token: token,
                                    package: branched_package,
                                    payload: creation_payload)
          end
        end

        before do
          package.save_file({ file: existing_branch_request_file, filename: '_branch_request' })
        end

        it { expect { subject.call }.not_to(change(Package, :count)) }
        it { expect { subject.call.source_file('_branch_request') }.not_to raise_error }

        it 'updates _branch_request file including new commit sha' do
          expect(subject.call.source_file('_branch_request')).to include('456')
        end

        it { expect { subject.call }.not_to(change(EventSubscription.where(eventtype: 'Event::BuildFail'), :count)) }
        it { expect { subject.call }.not_to(change(EventSubscription.where(eventtype: 'Event::BuildSuccess'), :count)) }
        it { expect { subject.call }.to(change { EventSubscription.where(eventtype: 'Event::BuildSuccess').last.payload }.from(creation_payload).to(update_payload)) }
      end

      context 'when the branched package did not exist' do
        let(:action) { 'synchronize' }
        let(:step_instructions) do
          {
            source_project: package.project.name,
            source_package: package.name,
            target_project: target_project_name
          }
        end

        it { expect { subject.call }.to(change(Package, :count).by(1)) }
        it { expect { subject.call }.to(change(EventSubscription, :count).from(0).to(2)) }
      end

      context 'when scmsync is active' do
        let(:project) { create(:project, name: 'foo_scm_synced_project', maintainer: user) }
        let(:package) { create(:package_with_file, name: 'bar_scm_synced_package', project: project) }
        let(:action) { 'opened' }
        let(:octokit_client) { instance_double(Octokit::Client) }
        let(:step_instructions) do
          {
            source_project: package.project.name,
            source_package: package.name,
            target_project: target_project_name
          }
        end
        let(:scmsync_url) { 'https://github.com/krauselukas/test_scmsync.git' }

        before do
          allow(Octokit::Client).to receive(:new).and_return(octokit_client)
          allow(octokit_client).to receive(:create_status).and_return(true)

          create(:repository, name: 'Unicorn_123', project: package.project, architectures: %w[x86_64 i586 ppc aarch64])
          create(:repository, name: 'openSUSE_Tumbleweed', project: package.project, architectures: ['x86_64'])
        end

        context 'on project level' do
          before do
            project.update(scmsync: scmsync_url)
          end

          it { expect(subject.call.scmsync).to eq("#{scmsync_url}?subdir=#{package.name}##{long_commit_sha}") }
          it { expect { subject.call }.to(change(Package, :count).by(1)) }
          it { expect { subject.call.source_file('_branch_request') }.to raise_error(Backend::NotFoundError) }
          it { expect { subject.call }.to(change(EventSubscription.where(eventtype: 'Event::BuildFail'), :count).by(1)) }
          it { expect { subject.call }.to(change(EventSubscription.where(eventtype: 'Event::BuildSuccess'), :count).by(1)) }
        end

        context 'on package level' do
          before do
            package.update(scmsync: scmsync_url)
          end

          it { expect(subject.call.scmsync).to eq("#{scmsync_url}##{long_commit_sha}") }
          it { expect { subject.call }.to(change(Package, :count).by(1)) }
          it { expect { subject.call.source_file('_branch_request') }.to raise_error(Backend::NotFoundError) }
          it { expect { subject.call }.to(change(EventSubscription.where(eventtype: 'Event::BuildFail'), :count).by(1)) }
          it { expect { subject.call }.to(change(EventSubscription.where(eventtype: 'Event::BuildSuccess'), :count).by(1)) }
        end

        context 'on a package level with a subdir query' do
          subdir = '?subdir=hello_world01'
          before do
            package.update(scmsync: scmsync_url + subdir)
          end

          it { expect(subject.call.scmsync).to eq("#{scmsync_url}#{subdir}##{long_commit_sha}") }
          it { expect { subject.call.source_file('_branch_request') }.to raise_error(Backend::NotFoundError) }
        end

        context 'on a package level with a branch fragment' do
          fragment = '#krauselukas-patch-2'
          before do
            package.update(scmsync: scmsync_url + fragment)
          end

          it { expect(subject.call.scmsync).to eq("#{scmsync_url}##{long_commit_sha}") }
          it { expect { subject.call.source_file('_branch_request') }.to raise_error(Backend::NotFoundError) }
        end

        context 'on a package level with a subdir query and a branch fragment' do
          subdir = '?subdir=hello_world01'
          fragment = '#krauselukas-patch-2'
          before do
            package.update(scmsync: scmsync_url + subdir + fragment)
          end

          it { expect(subject.call.scmsync).to eq("#{scmsync_url}#{subdir}##{long_commit_sha}") }
          it { expect { subject.call.source_file('_branch_request') }.to raise_error(Backend::NotFoundError) }
        end
      end
    end

    context 'for a closed_merged SCM webhook event' do
      skip('WIP')
    end

    context 'for a reopened event SCM webhook event' do
      skip('WIP')
    end
  end

  describe '#skip_repositories?' do
    let(:project) { create(:project, name: 'foo_project', maintainer: user) }
    let(:package) { create(:package_with_file, name: 'bar_package', project: project) }
    let(:scm_webhook) do
      SCMWebhook.new(payload: {
                       scm: 'github',
                       event: 'pull_request',
                       action: 'opened',
                       pr_number: 1,
                       source_repository_full_name: 'reponame',
                       commit_sha: long_commit_sha,
                       target_repository_full_name: 'openSUSE/open-build-service'
                     })
    end

    context 'when add_repositories is enabled' do
      let(:step_instructions) { { source_project: package.project.name, source_package: package.name, target_project: target_project_name, add_repositories: 'enabled' } }

      it { expect(subject.send(:skip_repositories?)).not_to be_truthy }
    end

    context 'when add_repositories is disabled' do
      let(:step_instructions) { { source_project: package.project.name, source_package: package.name, target_project: target_project_name, add_repositories: 'disabled' } }

      it { expect(subject.send(:skip_repositories?)).to be_truthy }
    end

    context 'when add_repositories is blank' do
      let(:step_instructions) { { source_project: package.project.name, source_package: package.name, target_project: target_project_name } }

      it { expect(subject.send(:skip_repositories?)).not_to be_truthy }
    end
  end

  describe '#check_source_access' do
    let(:project) { create(:project, name: 'foo_project', maintainer: user) }
    let(:scm_webhook) do
      SCMWebhook.new(payload: {
                       scm: 'github',
                       event: 'pull_request',
                       action: 'opened',
                       pr_number: 1,
                       source_repository_full_name: 'reponame',
                       commit_sha: long_commit_sha,
                       target_repository_full_name: 'openSUSE/open-build-service'
                     })
    end
    let(:step_instructions) do
      {
        source_project: project.name,
        source_package: 'this_package_does_not_exist',
        target_project: target_project_name
      }
    end

    it { expect { subject.call }.to raise_error(BranchPackage::Errors::CanNotBranchPackageNotFound) }
  end
end
