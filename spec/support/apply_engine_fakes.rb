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

class ApplyEngineFakes::Handler < Apply::Handler::Base
  add_step ApplyEngineFakes::PrepareStep
  add_step ApplyEngineFakes::SubmitStep, label: 'fake'
end
