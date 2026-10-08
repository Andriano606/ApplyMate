# frozen_string_literal: true

# A two-step pipeline for Runner specs. Each step forwards to its class-level `observe`, which does nothing;
# specs stub `observe` to look at the run mid-step or to raise a Halt / exception / claim the submit.
module ApplyEngineFakes; end

class ApplyEngineFakes::PrepareStep < Apply::Operation::Base
  stage :fake_prepare

  def self.observe(_ctx, **); end

  private

  def run!(ctx:, **options)
    self.class.observe(ctx, **options.except(:apply, :handler))
  end
end

class ApplyEngineFakes::SubmitStep < Apply::Operation::Base
  stage :fake_submit

  def self.observe(_ctx, **); end

  private

  def run!(ctx:, **options)
    self.class.observe(ctx, **options.except(:apply, :handler))
  end
end

# Stages the Runner may skip: the digest and the restore hook are class-level (stub `digest` / `restored` / `observe`
# in a spec). Default digest 'v1'; run! stores { 'ran' => <stage> } as the step result.
module ApplyEngineFakes::DigestStage
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def digest(_ctx, **)
      'v1'
    end

    def restored(_ctx, _result); end

    def observe(_ctx, **); end

    def input_digest(ctx, **options)
      digest(ctx, **options)
    end

    def restore(ctx, result)
      restored(ctx, result)
    end
  end

  private

  def run!(ctx:, **options)
    self.class.observe(ctx, **options.except(:apply, :handler))
    step_result(ran: self.class.stage.to_s)
  end
end

class ApplyEngineFakes::DigestOne < Apply::Operation::Stage::Base
  include ApplyEngineFakes::DigestStage

  stage :fake_digest_one
end

class ApplyEngineFakes::DigestTwo < Apply::Operation::Stage::Base
  include ApplyEngineFakes::DigestStage

  stage :fake_digest_two
end

class ApplyEngineFakes::Handler < Apply::Handler::Base
  add_step ApplyEngineFakes::PrepareStep
  add_step ApplyEngineFakes::SubmitStep, label: 'fake'
end

# A scope-less step, a :survey scope of two digest stages and a :submit scope.
class ApplyEngineFakes::ScopedHandler < Apply::Handler::Base
  add_step ApplyEngineFakes::PrepareStep
  session_scope(:survey) do
    add_step ApplyEngineFakes::DigestOne
    add_step ApplyEngineFakes::DigestTwo
  end
  session_scope(:submit) do
    add_step ApplyEngineFakes::SubmitStep
  end
end
