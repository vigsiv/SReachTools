function [lb_stoch_reach_avoid, optimal_input_vector] =...
    computeCcLowerBoundStochReachAvoidPwlRisk( ...
        sys,...
        time_horizon,...
        concat_input_space_A, ... 
        concat_input_space_b, ...
        concat_target_tube_A, ... 
        concat_target_tube_b, ...
        H, ...
        mean_X_sans_input, ...
        cov_X_sans_input, ...
        desired_accuracy)
% SReachTools/stochasticReachAvoid/computeCcLowerBoundStochReachAvoidPwlRisk:
% Solve the stochastic reach-avoid problem (lower bound on the probability and
% an open-loop controller synthesis) using chance-constrained convex
% optimization optimization (Internal function --- assumes arguments are all ok)
% =============================================================================
%
% computeCcLowerBoundStochReachAvoidPwlRisk implements the chance-constrained
% convex underapproximation to the terminal hitting-time stochastic reach-avoid
% problem discussed in
%
% K. Lesser, M. Oishi, and R. Erwin, "Stochastic reachability for control of
% spacecraft relative motion," in IEEE Conference on Decision and Control (CDC),
% 2013.
%
% and reformulated in
%
% A. Vinod, V. Sivaramakrishnan, and M. Oishi, CSS-L, 2018 (submitted) TODO
%
% USAGE: This function is intended for internal use as it does not sanitize the
% inputs. Please use getLowerBoundStochReachAvoid instead.
%
% =============================================================================
%   [lb_stoch_reach_avoid, optimal_input_vector] =...
%       computeCcLowerBoundStochReachAvoidPwlRisk( ...
%           sys, ...
%           time_horizon, ...
%           concat_input_space_A, ... 
%           concat_input_space_b, ...
%           concat_target_tube_A, ... 
%           concat_target_tube_b, ...
%           H, ...
%           mean_X_sans_input, ...
%           cov_X_sans_input, ...
%           desired_accuracy)
% 
% Inputs:
% -------
%   sys                  - LtiSystem object describing the system to be verified
%   time_horizon         - Time horizon of the stochastic reach-avoid problem
%   concat_input_space_A,
%    concat_input_space_b- (A,b) Halfspace representation for the
%                           polytope U^{time_horizon} set.        
%   concat_target_tube_A,
%    concat_target_tube_b- (A,b) Halfspace representation for the target tube.
%                           For example, the terminal reach-avoid problem
%                           requires a polytope of the form
%                           safe_set^{time_horizon-1} x target_set.        
%   H                    - Concatenated input matrix (see
%                           @LtiSystem/getConcatMats for the notation used)
%   mean_X_sans_input    - Mean of X without the influence of the input
%   cov_X_sans_input     - Covariance of X without the influence of the input
%   desired_accuracy     - Desired accuracy for the optimal stochastic
%                           reach-avoid probability [If unsure, use 1e-3]
%
% Outputs:
% --------
%   lb_stoch_reach_avoid - Lower bound on the terminal-hitting stochastic
%                          reach avoid problem computed using Fourier
%                          transform and convex optimization
%   optimal_input_vector - Optimal open-loop policy
%                          ((sys.input_dim) *
%                          time_horizon)-dimensional vector 
%                          U = [u_0; u_1; ...; u_N] (column vector)
%
% See also getLowerBoundStochReachAvoid,
% computeCcLowerBoundStochReachAvoidIterRisk, and
% computeFtLowerBoundStochReachAvoid.
%
% Notes:
% ------
% * NOT ACTIVELY TESTED: Builds on other tested functions.
% * MATLAB DEPENDENCY: Uses MATLAB's Statistics and Machine Learning Toolbox.
%                      Needs norminv
% * EXTERNAL DEPENDENCY: Uses MPT3 and CVX (optional)
%                      Needs MPT3 for defining a controlled system and the
%                      definition of the safe and the target (polytopic) sets
%                      Needs CVX to setup a convex optimization problem that
%                      initializes the patternsearch-based optimization. If CVX
%                      is unavailable, the user may provide a guess for the
%                      initialization.
% * See @LtiSystem/getConcatMats for more information about the
%     notation used.
% 
% ============================================================================
% 
% This function is part of the Stochastic Reachability Toolbox.
% License for the use of this function is given in
%      https://github.com/abyvinod/SReachTools/blob/master/LICENSE
% 
%

    %% House-keeping for the event where probability <0.5 
    % (TODO: Remove once MILP is encoded)
    lb_stoch_reach_avoid = -1;
    optimal_input_vector = nan(sys.input_dim * time_horizon,1);
    
    %% Compute M --- the number of polytopic halfspaces to worry about
    no_linear_constraints = size(concat_target_tube_A,1);

    %% Compute \sqrt{h_i^\top * \Sigma_X_no_input * h_i}
    sigma_vector = diag(sqrt(diag(concat_target_tube_A *...
        cov_X_sans_input * concat_target_tube_A')));

    % TODO: Translate desired_accuracy to piecewise_count
    piecewise_count = 1e3;
    [invcdf_approx_A, invcdf_approx_b, lower_bound_on_deltai] =...
        computeNormCdfInvOverApprox(piecewise_count);
    
    %% Solve the feasibility problem
    cvx_begin quiet
        variable U_vector(sys.input_dim * time_horizon,1);
        variable mean_X(sys.state_dim * time_horizon, 1);
        variable deltai(no_linear_constraints, 1);
        variable norminvover(no_linear_constraints, 1);
        minimize sum(deltai)
        subject to
            mean_X == mean_X_sans_input + H * U_vector;
            concat_input_space_A * U_vector <= concat_input_space_b;
            for deltai_indx=1:no_linear_constraints
                norminvover(deltai_indx) >= invcdf_approx_A.*...
                    deltai(deltai_indx) + invcdf_approx_b; 
            end
            concat_target_tube_A * mean_X + sigma_vector * norminvover...
                <= concat_target_tube_b;
            deltai >= lower_bound_on_deltai;
            deltai <= 0.5;
    cvx_end
    %% Overwrite the solutions
    if strcmpi(cvx_status, 'Solved')
        lb_stoch_reach_avoid = 1-sum(deltai);
        optimal_input_vector = U_vector;    
    end
end
