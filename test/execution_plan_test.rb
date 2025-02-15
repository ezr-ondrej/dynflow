require_relative 'test_helper'

module Dynflow
  module ExecutionPlanTest
    describe ExecutionPlan do

      include PlanAssertions

      let(:world) { WorldFactory.create_world }

      let :issues_data do
        [{ 'author' => 'Peter Smith', 'text' => 'Failing test' },
         { 'author' => 'John Doe', 'text' => 'Internal server error' }]
      end

      describe 'serialization' do

        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
        end

        let :deserialized_execution_plan do
          world.persistence.load_execution_plan(execution_plan.id)
        end

        describe 'serialized execution plan' do

          before { execution_plan.save }
          after { world.persistence.delete_execution_plans(:uuid => execution_plan.id) }

          it 'restores the plan properly' do
            assert deserialized_execution_plan.valid?
            deserialized_execution_plan.id.must_equal execution_plan.id
            deserialized_execution_plan.label.must_equal execution_plan.label

            assert_steps_equal execution_plan.root_plan_step, deserialized_execution_plan.root_plan_step
            assert_equal execution_plan.steps.keys, deserialized_execution_plan.steps.keys

            deserialized_execution_plan.steps.each do |id, step|
              assert_steps_equal(step, execution_plan.steps[id])
            end

            assert_run_flow_equal execution_plan, deserialized_execution_plan
          end

          it 'handles issues with loading the data' do
            world.persistence.adapter.send(:table, :step)
              .where(execution_plan_uuid: execution_plan.id).delete
            refute deserialized_execution_plan.valid?
            assert_equal Dynflow::Errors::DataConsistencyError, deserialized_execution_plan.exception.class
            [:label, :state, :started_at, :ended_at].each do |attr|
              assert_equal execution_plan.send(attr).to_s,
                           deserialized_execution_plan.send(attr).to_s,
                           "invalid plan is supposed to still store #{attr}"
            end
            [:execution_time, :real_time].each do |attr|
              assert_equal execution_plan.send(attr).to_f,
                           deserialized_execution_plan.send(attr).to_f,
                           "invalid plan is supposed to still store #{attr}"
            end
            assert_equal execution_plan.execution_history.events,
                         deserialized_execution_plan.execution_history.events,
                         "invalid plan is supposed to still store execution history"
          end

        end

      end

      describe '#label' do
        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
        end

        let :dummy_execution_plan do
          world.plan(Support::CodeWorkflowExample::Dummy)
        end

        it 'is determined by the action#label method of entry action' do
          execution_plan.label.must_equal 'Support::CodeWorkflowExample::FastCommit'
          dummy_execution_plan.label.must_equal 'dummy_action'
        end
      end
      describe '#result' do

        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
        end

        describe 'for error in planning phase' do

          before { execution_plan.steps[2].set_state :error, true }

          it 'should be :error' do
            execution_plan.result.must_equal :error
            execution_plan.error?.must_equal true
          end

        end

        describe 'for error in running phase' do

          before do
            step_id = execution_plan.run_flow.all_step_ids[2]
            execution_plan.steps[step_id].set_state :error, true
          end

          it 'should be :error' do
            execution_plan.result.must_equal :error
          end

        end

        describe 'for pending step in running phase' do

          before do
            step_id = execution_plan.run_flow.all_step_ids[2]
            execution_plan.steps[step_id].set_state :pending, true
          end

          it 'should be :pending' do
            execution_plan.result.must_equal :pending
          end

        end

        describe 'for all steps successful or skipped' do

          before do
            execution_plan.run_flow.all_step_ids.each_with_index do |step_id, index|
              step = execution_plan.steps[step_id]
              step.set_state (index == 2) ? :skipped : :success, true
            end
          end

          it 'should be :warning' do
            execution_plan.result.must_equal :warning
          end

        end

      end

      describe 'sub plans' do
        let(:execution_plan) do
          world.plan(Support::CodeWorkflowExample::IncomingIssues, issues_data)
        end

        it 'does not have itself as a sub plan' do
          assert execution_plan.actions.count >= 2
          execution_plan.sub_plans.must_be :empty?
        end
      end

      describe 'plan steps' do
        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::IncomingIssues, issues_data)
        end

        it 'stores the information about the sub actions' do
          assert_plan_steps <<-PLAN_STEPS, execution_plan
            IncomingIssues
              IncomingIssue
                Triage
                  UpdateIssue
                  NotifyAssignee
              IncomingIssue
                Triage
                  UpdateIssue
                  NotifyAssignee
          PLAN_STEPS
        end

      end

      describe 'persisted action' do

        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::IncomingIssues, issues_data)
        end

        let :action do
          step = execution_plan.steps[4]
          world.persistence.load_action(step)
        end

        it 'stores the ids for plan, run and finalize steps' do
          action.plan_step_id.must_equal 3
          action.run_step_id.must_equal 4
          action.finalize_step_id.must_equal 5
        end
      end

      describe 'custom plan id' do
        let(:sample_uuid) { '60366107-9910-4815-a6c6-bc45ee2ea2b8' }
        let :execution_plan do
          world.plan_with_options(action_class: Support::CodeWorkflowExample::IncomingIssues,
                                  args: [issues_data],
                                  id: sample_uuid)
        end

        it 'allows setting custom id for the execution plan' do
          execution_plan.id.must_equal sample_uuid
        end
      end

      describe 'planning algorithm' do

        describe 'single dependencies' do
          let :execution_plan do
            world.plan(Support::CodeWorkflowExample::IncomingIssues, issues_data)
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Concurrence
                Dynflow::Flows::Sequence
                  4: Triage(pending) {"author"=>"Peter Smith", "text"=>"Failing test"}
                  7: UpdateIssue(pending) {"author"=>"Peter Smith", "text"=>"Failing test", "assignee"=>Step(4).output[:classification][:assignee], "severity"=>Step(4).output[:classification][:severity]}
                  9: NotifyAssignee(pending) {"triage"=>Step(4).output}
                Dynflow::Flows::Sequence
                  13: Triage(pending) {"author"=>"John Doe", "text"=>"Internal server error"}
                  16: UpdateIssue(pending) {"author"=>"John Doe", "text"=>"Internal server error", "assignee"=>Step(13).output[:classification][:assignee], "severity"=>Step(13).output[:classification][:severity]}
                  18: NotifyAssignee(pending) {"triage"=>Step(13).output}
            RUN_FLOW
          end

        end

        describe 'error in planning phase' do
          let :execution_plan do
            world.plan(Support::CodeWorkflowExample::IncomingIssues, [:fail] + issues_data)
          end

          it 'stops the planning right after the first error occurred' do
            execution_plan.steps.size.must_equal 2
          end
        end

        describe 'multi dependencies' do
          let :execution_plan do
            world.plan(Support::CodeWorkflowExample::Commit, 'sha' => 'abc123')
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Sequence
                Dynflow::Flows::Concurrence
                  3: Ci(pending) {"commit"=>{"sha"=>"abc123"}}
                  5: Review(pending) {"commit"=>{"sha"=>"abc123"}, "reviewer"=>"Morfeus", "result"=>true}
                  7: Review(pending) {"commit"=>{"sha"=>"abc123"}, "reviewer"=>"Neo", "result"=>true}
                9: Merge(pending) {"commit"=>{"sha"=>"abc123"}, "ci_result"=>Step(3).output[:passed], "review_results"=>[Step(5).output[:passed], Step(7).output[:passed]]}
            RUN_FLOW
          end
        end

        describe 'sequence and concurrence keyword used' do
          let :execution_plan do
            world.plan(Support::CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Sequence
                Dynflow::Flows::Concurrence
                  3: Ci(pending) {"commit"=>{"sha"=>"abc123"}}
                  5: Review(pending) {"commit"=>{"sha"=>"abc123"}, "reviewer"=>"Morfeus", "result"=>true}
                7: Merge(pending) {"commit"=>{"sha"=>"abc123"}, "ci_result"=>Step(3).output[:passed], "review_results"=>[Step(5).output[:passed]]}
            RUN_FLOW
          end
        end

        describe 'subscribed action' do
          let :execution_plan do
            world.plan(Support::CodeWorkflowExample::DummyTrigger, {})
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Concurrence
                3: DummySubscribe(pending) {}
                5: DummyMultiSubscribe(pending) {}
            RUN_FLOW
          end
        end

        describe 'finalize flow' do

          let :execution_plan do
            world.plan(Support::CodeWorkflowExample::IncomingIssues, issues_data)
          end

          it 'plans the finalize steps in a sequence' do
            assert_finalize_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Sequence
                5: Triage(pending) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"}
                10: NotifyAssignee(pending) {\"triage\"=>Step(4).output}
                14: Triage(pending) {\"author\"=>\"John Doe\", \"text\"=>\"Internal server error\"}
                19: NotifyAssignee(pending) {\"triage\"=>Step(13).output}
                20: IncomingIssues(pending) {\"issues\"=>[{\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"}, {\"author\"=>\"John Doe\", \"text\"=>\"Internal server error\"}]}
            RUN_FLOW
          end

        end
      end

      describe '#cancel' do
        include TestHelpers

        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::CancelableSuspended, { text: 'cancel-external' })
        end

        it 'cancels' do
          finished = world.execute(execution_plan.id)
          plan = wait_for do
            plan = world.persistence.load_execution_plan(execution_plan.id)
            if plan.cancellable?
              plan
            end
          end
          cancel_events = plan.cancel
          cancel_events.size.must_equal 1
          cancel_events.each(&:wait)
          finished.wait
        end

        it 'force cancels' do
          finished = world.execute(execution_plan.id)
          plan = wait_for do
            plan = world.persistence.load_execution_plan(execution_plan.id)
            if plan.cancellable?
              plan
            end
          end
          cancel_events = plan.cancel true
          cancel_events.size.must_equal 1
          cancel_events.each(&:wait)
          finished.wait
        end
      end

      describe 'accessing actions results' do
        let :execution_plan do
          world.plan(Support::CodeWorkflowExample::IncomingIssues, issues_data)
        end

        it 'provides the access to the actions data via steps #action' do
          execution_plan.steps.size.must_equal 20
          execution_plan.steps.each do |_, step|
            step.action(execution_plan).phase.must_equal Action::Present
          end
        end
      end

      describe ExecutionPlan::Steps::Error do

        it "doesn't fail when deserializing with missing class" do
          error = ExecutionPlan::Steps::Error.new_from_hash(exception_class: "RenamedError",
                                                            message: "This errror is not longer here",
                                                            backtrace: [])
          error.exception_class.name.must_equal "RenamedError"
          error.exception_class.to_s.must_equal "Dynflow::Errors::UnknownError[RenamedError]"
          error.exception.inspect.must_equal "Dynflow::Errors::UnknownError[RenamedError]: This errror is not longer here"
        end

      end

      describe 'with singleton actions' do
        class SingletonAction < ::Dynflow::Action
          include ::Dynflow::Action::Singleton

          def run
            if input[:fail]
              raise "Controlled Failure"
            end
          end
        end

        it 'unlocks the locks on transition to stopped' do
          plan = world.plan(SingletonAction)
          plan.state.must_equal :planned
          lock_filter = ::Dynflow::Coordinator::SingletonActionLock
                          .unique_filter plan.entry_action.class.name
          world.coordinator.find_locks(lock_filter).count.must_equal 1
          plan = world.execute(plan.id).wait!.value
          plan.state.must_equal :stopped
          plan.result.must_equal :success
          world.coordinator.find_locks(lock_filter).count.must_equal 0
        end

        it 'unlocks the locks on transition to paused' do
          plan = world.plan(SingletonAction, :fail => true)
          plan.state.must_equal :planned
          lock_filter = ::Dynflow::Coordinator::SingletonActionLock
                          .unique_filter plan.entry_action.class.name
          world.coordinator.find_locks(lock_filter).count.must_equal 1
          plan = world.execute(plan.id).wait!.value
          plan.state.must_equal :paused
          plan.result.must_equal :error
          world.coordinator.find_locks(lock_filter).count.must_equal 0
        end
      end
    end
  end
end
