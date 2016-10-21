local train = {}

require 'optim'
require 'image'

-- local packages
local prednet = require 'prednet'

function train:__init(opt)
   -- Model parameter
   self.layers = opt.layers

   -- Optimizer parameter
   self.optimState = {learningRate      = opt.learningRate,
                      momentum          = opt.momentum,
                      learningRateDecay = opt.learningRateDecay,
                      weightDecay       = opt.weightDecay}

   -- Dataset parameters
   self.channels = opt.channels

   local dataFile, dataFileTest
   if opt.dataBig then
      dataFile     = opt.datapath .. '/data-big-train.t7'
      dataFileTest = otp.datapath .. 'data-big-test.t7'
   else
      dataFile     = opt.datapath .. '/data-small-train.t7'
      dataFileTest = opt.datapath .. 'data-small-test.t7'
   end
   self.dataset = torch.load(dataFile):float()/255                  -- load MNIST
   print("Loaded " .. self.dataset:size(1) .. " image sequences")

   self.res = self.dataset:size(4)
   self.seq = self.dataset:size(2)
   print("Image resolution: " .. self.res .. " x " .. self.res)

   opt.seq = self.seq
   opt.res = self.res

   -- Initialize model generator
   prednet:__init(opt)
   -- Get the model unwrapped over time as well as the prototype
   self.model, self.prototype = prednet:getModel()

   -- Put model parameters into contiguous memory
   self.w, self.dE_dw = self.model:getParameters()
   print("# of parameters " .. self.w:nElement())

   return self.prototype
end

local criterion = nn.MSECriterion()       -- citerion to calculate loss

function train:updateModel()
   local model = self.model
   local w = self.w
   local dE_dw = self.dE_dw

   model:training()                       -- Ensure model is in training mode

   local trainError = 0
   local interFrameError = 0
   local optimState = self.optimState
   local L = self.layers
   local channels = self.channels
   local res = self.res
   local seq = self.seq

   local dataSize = self.dataset:size(1)
   local shuffle = torch.randperm(dataSize)  -- Get shuffled index of dataset

   local time = sys.clock()

   -- Initial state/input of the network
   -- {imageSequence, RL+1, R1, E1, R2, E2, ..., RL, EL}
   local H0 = {}
   H0[3] = torch.zeros(channels[1], res, res)                  -- C1[0]
   H0[4] = torch.zeros(channels[1], res, res)                  -- H1[0]
   H0[5] = torch.zeros(2*channels[1], res, res)                -- E1[0]

   for l = 2, L do
      res = res / 2
      H0[3*l]   = torch.zeros(channels[l], res, res)           -- C1[0]
      H0[3*l+1] = torch.zeros(channels[l], res, res)           -- Hl[0]
      H0[3*l+2] = torch.zeros(2*channels[l], res, res)         -- El[0]
   end
   res = res / 2
   H0[2] = torch.zeros(channels[L+1], res, res)                -- RL+1


   for itr = 1, dataSize do
      xlua.progress(itr, dataSize)

      -- Dimension seq x channels x height x width
      local xSeq = self.dataset[shuffle[itr]]                  -- 1 -> 20 input image

      H0[1] = xSeq:clone()

      local h = {}
      local prediction = xSeq:clone()

      local eval_E = function()
         -- Output is table of all predictions
         h = model:forward(H0)
         -- Merge all the predictions into a batch from 2 -> LAST sequence
         --       Table of 2         Batch of 2
         -- {(64, 64), (64, 64)} -> (2, 64, 64)
         for i = 2, #h do
            prediction[i] = h[i]
         end

         local err = criterion:forward(prediction, xSeq)

         -- Reset gradParameters
         model:zeroGradParameters()

         -- Backward pass
         local dE_dh = criterion:backward(prediction, xSeq)

         -- model:backward() expects dE_dh to be a table of sequence length
         -- Since 1st frame was ignored while calculating error (prediction[1] = xSeq[1]),
         -- 1st tensor in dE_dhTable is just a zero tensor
         local dE_dhTable = {}
         dE_dhTable[1] = dE_dh[1]:clone():zero()
         for i = 2, seq do
            dE_dhTable[i] = dE_dh[i]
         end

         model:backward(H0, dE_dhTable)

         self.dispWin = image.display{image={xSeq[seq][1], prediction[seq]},
                                      legend='Real | Pred', win = self.dispWin}

         return err, dE_dw
      end

      local err
      w, err = optim.adam(eval_E, w, optimState)

      trainError = trainError + err[1]
      interFrameError = interFrameError
                      + criterion:forward(prediction[{{2, seq}}], xSeq[{{1, seq-1}}])
   end

   -- Calculate time taken by 1 epoch
   time = sys.clock() - time
   trainError = trainError/dataSize
   interFrameError = interFrameError/dataSize
   print("\nTraining Error: " .. trainError)
   print("Time taken to learn 1 sample: " .. (time*1000/dataSize) .. "ms")

   collectgarbage()
   return trainError, interFrameError
end

return train
