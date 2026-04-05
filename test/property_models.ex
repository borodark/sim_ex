defmodule Sim.PropertyModels.Barbershop do
  use Sim.DSL

  model :barbershop do
    resource(:barber, capacity: 1)

    process :customer do
      arrive(every: exponential(10.0))
      seize(:barber)
      hold(exponential(8.0))
      release(:barber)
      depart
    end
  end
end

defmodule Sim.PropertyModels.NoRework do
  use Sim.DSL

  model :no_rework do
    resource(:machine, capacity: 1)
    resource(:rework, capacity: 1)

    process :part do
      arrive(every: exponential(5.0))
      seize(:machine)
      hold(exponential(3.0))
      release(:machine)
      decide(0.0, :rework_loop)
      depart
      label(:rework_loop)
      seize(:rework)
      hold(exponential(4.0))
      release(:rework)
      depart
    end
  end
end

defmodule Sim.PropertyModels.AllRework do
  use Sim.DSL

  model :all_rework do
    resource(:machine, capacity: 1)
    resource(:rework, capacity: 1)

    process :part do
      arrive(every: exponential(5.0))
      seize(:machine)
      hold(exponential(3.0))
      release(:machine)
      decide(1.0, :rework_loop)
      depart
      label(:rework_loop)
      seize(:rework)
      hold(exponential(4.0))
      release(:rework)
      depart
    end
  end
end

defmodule Sim.PropertyModels.Combine1 do
  use Sim.DSL

  model :combine1 do
    resource(:machine, capacity: 2)

    process :part do
      arrive(every: exponential(5.0))
      seize(:machine)
      hold(exponential(3.0))
      release(:machine)
      combine(1)
      depart
    end
  end
end

defmodule Sim.PropertyModels.SplitCombine do
  use Sim.DSL

  model :split_combine do
    resource(:cutter, capacity: 2)
    resource(:assembler, capacity: 2)

    process :part do
      arrive(every: exponential(10.0))
      seize(:cutter)
      hold(exponential(3.0))
      release(:cutter)
      split(3)
      seize(:assembler)
      hold(exponential(3.0))
      release(:assembler)
      combine(3)
      depart
    end
  end
end
